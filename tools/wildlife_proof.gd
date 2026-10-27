extends SceneTree
## Deterministic, windowed wildlife proof. Run with GRIDFALL_OFFLINE=1, GRIDFALL_NEW_CITY=1 and an
## isolated XDG_DATA_HOME, e.g.
##   DISPLAY=:1 godot --path . -s tools/wildlife_proof.gd -- --output=<absolute directory>
## Images (full frames and crops) go to --output=. This uses the real feature clocks and renderer;
## only the camera, the light and the fixtures are staged.
##
## Four passes the round-3 work owes:
## 1. A live walker-dog: a resident who lives with a dog comes out with it on its lead, walks it at
##    heel along the sidewalk past the hero, the lead drawn from their hand to its collar.
## 2. The perched birds: a flock on a lamp top or a roof edge above the street, the hero's shout
##    below sending them up together to wheel over the roofs, then gliding back onto their points.
## 3. A squirrel on its lawn at the foot of its tree, bounding and sitting up to nibble, then the
##    hero walking up sending it chattering up the trunk to cling there.
## 4. The hero's car horn (horn_sounded, the drive feature's street radius) sending the pigeons
##    foraging on the sidewalk up together to wheel over the street.
## 5. The interplay: a dog after a cat — the cat bolting up its refuge trunk, the dog barking up
##    at it from where the fence holds it — and a hunter cat stalking the lawn's squirrel.
## Then the night and rain audit of every animal kind (shelter/quiet, bodies drawn, no z-fighting).

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")
const BODIES := preload("res://scripts/fp/animals/dog_bodies.gd")
const PR := preload("res://scripts/fp/animals/perches.gd")
const PG := preload("res://scripts/fp/animals/pigeons.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const SQ := preload("res://scripts/fp/animals/squirrels.gd")
const LIFE := preload("res://scripts/fp/animals/squirrel_life.gd")
const CAT_LIFE := preload("res://scripts/fp/animals/cat_life.gd")
const SD := preload("res://scripts/sim/sim_defs.gd")
const DRIVE := preload("res://scripts/fp/drive/drive_feature.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DT := 1.0 / 60.0
## The dog's owner walks at a walk (m/s), the pace the lead shot is taken at.
const WALK_MPS := 1.4

var ctx: FpContext
var traffic: FpFeature
var streetscape: FpFeature
var f: FpFeature
var pack: PACK
var cam: Camera3D
var output: String = "/tmp/gf-r3-wildlife-proof"
var failed: bool = false


func _init() -> void:
	await process_frame
	_shots_dir()
	ctx = K.make_ctx(
		get_root(), {"view": true, "render": true, "grow": true, "camera_mode": "third"}
	)
	# On foot, as the game's own boot leaves the view: the orbit-only layers (mayor bots, labels,
	# the territory borders) must not draw in a street-level shot.
	ctx.view.set_fp_mode(true)
	ctx.player.set_process(false)
	ctx.player.input_enabled = false
	ctx.sim.set_process(false)
	ctx.sky.set_process(false)
	ctx.hud.visible = false
	ctx.sky.fixed_hour = 13.0
	ctx.sky.hour = 13.0
	ctx.sky.night = 0.0
	# The sky's own clock is off (its _process is frozen), so put the midday look on by hand.
	ctx.sky.call("_apply", 1.0)
	traffic = K.make_feature(ctx, "traffic")
	streetscape = K.make_feature(ctx, "streetscape")
	f = K.make_feature(ctx, "animals")
	for feature: FpFeature in [traffic, streetscape, f]:
		feature.set_process(false)
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	(f.get("bodies") as BODIES).blocking = true
	var cats_node: Node = f.get("cats")
	(cats_node.get("bodies") as Object).set("blocking", true)
	pack = f.get("pack")
	cam = Camera3D.new()
	cam.name = "ProofCam"
	cam.fov = 34.0
	get_root().add_child(cam)
	await _walker_dog()
	await _perched()
	await _squirrels()
	await _horn()
	await _chase_and_stalk()
	await _night()
	await _rain()
	print("WILDLIFE_PROOF: %s (%s)" % ["FAIL" if failed else "PASS", output])
	quit(1 if failed else 0)


## Reads --output=<absolute directory> (the default stays) and makes sure it exists.
func _shots_dir() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(output)


# ------------------------------------------------------------------ the bench


## Steps the real clocks secs (in 1/60 s): traffic's step, the animals feature's tick and the
## player's view, with the camera put back where the shot wants it.
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		traffic.call("step", DT)
		f.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)
		traffic.call("sync_visuals", DT)
		await process_frame


## Points the proof camera at focus from eye and makes it current.
func _frame(eye: Vector3, focus: Vector3) -> void:
	cam.global_position = eye
	cam.look_at(focus)
	cam.make_current()


## A camera eye at angle_deg round focus, dist_m off and up_m above it, looking at focus.
func _eye(focus: Vector3, angle_deg: float, dist_m: float, up_m: float) -> Vector3:
	var a := deg_to_rad(angle_deg)
	return focus + Vector3(cos(a), 0.0, sin(a)) * dist_m * WS.M + Vector3.UP * up_m * WS.M


## Saves the frame as name.png; when focus is finite, also a crop centred on it covering crop_m
## metres as name_crop.png.
func _shot(name: String, focus := Vector3.INF, crop_m := 2.5) -> void:
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	var r := img.save_png(output.path_join(name + ".png"))
	failed = failed or r != OK
	print("WILDLIFE_PROOF: %s %s" % [name, error_string(r)])
	if not focus.is_finite():
		return
	var sp := cam.unproject_position(focus)
	var d := cam.global_position.distance_to(focus)
	var px := float(img.get_height()) / (2.0 * d * tan(deg_to_rad(cam.fov) * 0.5))
	var cap := mini(img.get_width(), img.get_height())
	var half := clampi(roundi(crop_m * 0.5 * px), 24, cap / 2)
	var size := Vector2i(half * 2, half * 2)
	var at := Vector2i(sp) - size / 2
	at.x = clampi(at.x, 0, maxi(0, img.get_width() - size.x))
	at.y = clampi(at.y, 0, maxi(0, img.get_height() - size.y))
	var region := img.get_region(Rect2i(at, size))
	var rc := region.save_png(output.path_join(name + "_crop.png"))
	failed = failed or rc != OK
	print("WILDLIFE_PROOF: %s_crop %s" % [name, error_string(rc)])


func _fail(what: String) -> void:
	failed = true
	print("WILDLIFE_PROOF: FAIL %s" % what)


# ------------------------------------------------------------------ 1. a live walker-dog


## A resident who lives with a dog comes out with it on its lead and walks it along the sidewalk
## past the hero; the shot frames the pair from the hero's side, at heel on the lead.
func _walker_dog() -> void:
	_quiet()
	_no_dogs_at_home()
	var st := await _stage_walker_dog()
	if st.is_empty() or st[1] == null:
		_fail("a sidewalk and a resident who lives with a dog")
		return
	var w: WK.Walker = st[0]
	var d: PACK.Dog = st[1]
	var run: Vector3 = (st[2] as Dictionary)["run"]
	for _k in range(roundi(2.2 / DT)):
		_walk_on(w, run, WALK_MPS)
		await process_frame
	# A close view from the dog's own side of the pair (past its shoulder, looking back), so the
	# dog is in front and the lead runs broadside from the owner's hand to its collar, clear of
	# the owner's skirt.
	var hand: Vector3 = d.hand
	var collar := pack.collar_of(d)
	var mid := (hand + collar) * 0.5
	var toward := d.pos - w.pos
	toward.y = 0.0
	toward = toward.normalized() if toward.length_squared() > 1e-12 else Vector3.RIGHT
	_frame(mid + toward * 2.4 * WS.M + Vector3.UP * 0.35 * WS.M, mid)
	await _shot("walker_dog", mid, 1.8)
	var left := Vector3(cos(w.yaw), 0.0, -sin(w.yaw))
	var at_heel := (d.pos - w.pos).dot(left) > 0.1 * WS.M
	if d.mode != "heel" or not d.clipped or not at_heel:
		_fail("the dog heeling on the lead (%s, clipped %s)" % [d.mode, d.clipped])


## Stages a resident who lives with a dog walking it along a sidewalk near the hero, and steps
## until its dog is out on the lead. [walker, dog, sidewalk], or [] when there is no sidewalk or
## owner (the dog may still be null while its body loads).
func _stage_walker_dog() -> Array:
	var walk := K.sidewalk(ctx, 0.6)
	var r := _owner(0, "park")
	if walk.is_empty() or r.is_empty():
		return []
	var run: Vector3 = walk["run"]
	ctx.player.teleport((walk["pos"] as Vector3) - run * 1.2 * WS.M, float(walk["yaw"]))
	var wk: WK = traffic.get("walkers")
	var w := wk.make("resident")
	w.extra = 0
	w.resident_id = str(r["id"])
	wk.stand(w, (walk["pos"] as Vector3) + run * 5.0 * WS.M, atan2(run.x, run.z))
	await _step(AF.SCAN_S + 0.2)
	return [w, _dog_of(w), walk]


## One frame with w walking mps along run (traffic leaves a standing walker be).
func _walk_on(w: WK.Walker, run: Vector3, mps: float) -> void:
	var p := w.pos + run * mps * WS.M * DT
	var y := ctx.collision.walk_height(p)
	p.y = y if not is_nan(y) else w.pos.y
	w.pos = p
	w.yaw = atan2(run.x, run.z)
	await _step(DT)


func _dog_of(w: WK.Walker) -> PACK.Dog:
	for d: PACK.Dog in pack.dogs:
		if d.walker == w.id:
			return d
	return null


## Removes every walker, so only the proof's own people are about.
func _quiet() -> void:
	K.quiet_walkers(traffic)


## Nobody in the city lives with a dog but the proof's own owner.
func _no_dogs_at_home() -> void:
	FRESH.no_dogs_at_home(ctx)


## The k-th resident with a home, made to live with a dog and to be out (state).
func _owner(k: int, state: String) -> Dictionary:
	return FRESH.dog_owner(ctx, k, state)


# ------------------------------------------------------------------ 2. the perched birds


## The nearest perch spot (a lamp top or a roof edge) with the hero's stand on the street below;
## the flock comes out, the hero's shout sends it up, and it glides back onto its points.
func _perched() -> void:
	var pr: PR = f.get("perches")
	var fl: FLOCK = pr.flock
	var spot := _perch_spot(pr)
	if spot.is_empty():
		_fail("a perch spot in the grown city")
		return
	var key := str(spot["key"])
	ctx.player.teleport(spot["stand"], 0.0)
	await _step(AF.SCAN_S + 0.2)
	var fk := _flock_of(fl, key)
	if fk == null:
		_fail("the spot's perch flock comes out")
		return
	var home: Vector3 = fk.home
	# Directly below the perch, so the shout reaches it (the perch sits over the roof edge, not
	# the middle of the lot's tile).
	var g := ctx.collision.walk_height(Vector3(home.x, 0.0, home.z))
	var under := Vector3(home.x, g if not is_nan(g) else 0.0, home.z)
	ctx.player.teleport(under, 0.0)
	var focus := home + Vector3.UP * 0.15 * WS.M
	_frame(_eye(focus, 200.0, 4.2, 1.2), focus)
	await _shot("perched", focus, 2.2)
	pr.startle(under, float(PR.STARTLE["shout"]))
	await _step(0.8)
	_frame(_eye(focus, 200.0, 6.0, 3.0), focus + Vector3.UP * 1.2 * WS.M)
	await _shot("perched_flush", focus + Vector3.UP * 1.2 * WS.M, 6.0)
	var up := true
	for b: FLOCK.Bird in fk.birds:
		up = up and b.air
	if not up:
		_fail("the shout sends the whole flock up")
	var back := await _wait_perched(fk)
	if back < 0.0:
		_fail("they glide back onto their own perches")
		return
	_frame(_eye(focus, 200.0, 4.2, 1.2), focus)
	await _shot("perched_back", focus, 2.2)


## The first perch spot of the grown city, with where the hero stands on the street below it (the
## shared fixture in fp_fresh_city.gd).
func _perch_spot(pr: PR) -> Dictionary:
	return FRESH.perch_spot(ctx, pr)


func _flock_of(fl: FLOCK, key: String) -> FLOCK.Flock:
	for fk: FLOCK.Flock in fl.flocks:
		if fk.key == key:
			return fk
	return null


## Steps until every bird is back on its perch with no take-off pending (at most 40 s); the
## seconds it took, or -1.
func _wait_perched(fk: FLOCK.Flock) -> float:
	var t := 0.0
	while t <= 40.0:
		var back := true
		for b: FLOCK.Bird in fk.birds:
			back = back and not b.air and b.delay <= 0.0 and b.pos.distance_to(b.goal) < 1e-6
		if back:
			return t
		await _step(0.25)
		t += 0.25
	return -1.0


# ------------------------------------------------------------------ 3. the squirrel


## The nearest squirrel spot (a lawn at the foot of a tree) with the hero's stand off it: it comes
## out, bounds about its patch and sits up to nibble, then the hero walking up sends it chattering
## for its trunk, up it and clinging there head-up.
func _squirrels() -> void:
	var sq: SQ = f.get("squirrels")
	var life: LIFE = sq.get("life")
	var spot := _squirrel_spot(sq)
	if spot.is_empty():
		_fail("a squirrel's lawn with a tree in the grown city")
		return
	var key := str(spot["key"])
	ctx.player.teleport(spot["stand"], 0.0)
	await _step(AF.SCAN_S + 0.2)
	var s := life.squirrel(key)
	if s == null:
		_fail("the spot's squirrel comes out")
		return
	# Give it a few seconds of foraging so the shot catches it up on its haunches nibbling.
	await _step(6.0)
	# Framed from the side of the trunk the squirrel is on: its lawn is only about a trunk's width
	# out, so a camera on any other side has the bark between it and the animal. The focus sits at
	# its body's middle (a little behind its origin, where the tail trails), so the whole animal
	# fits the crop.
	var tree: Array = s.tree
	var out := _out_from(tree, s.pos)
	var mid := s.pos - Vector3(sin(s.yaw), 0.0, cos(s.yaw)) * 0.05 * WS.M
	var focus := mid + Vector3.UP * 0.04 * WS.M
	_frame(mid + out * 1.1 * WS.M + Vector3.UP * 0.34 * WS.M, focus)
	await _shot("squirrel", focus, 1.0)
	_check(_flat(s.pos, s.home) <= SQ.FORAGE_R + 0.05, "squirrel: it keeps to the lawn by its tree")
	# The hero walks up to it: it chatters, dashes for its tree and runs up the trunk.
	ctx.player.teleport(s.pos + Vector3(0.3 * WS.M, 0.0, 0.0), 0.0)
	var t := 0.0
	var dashed := false
	while t <= 6.0:
		await _step(0.2)
		t += 0.2
		dashed = dashed or s.state in ["flee", "climb"]
		if s.state == "hold":
			break
	_check(dashed and s.state == "hold", "squirrel: the hero walking up sends it up its trunk")
	_check(
		s.climb_y >= LIFE.CLING_H - 0.005, "squirrel: it clings up the trunk (%.3f u)" % s.climb_y
	)
	# On the trunk, framed from the same side, on the animal's body (as the forage shot) so the
	# whole squirrel reads against the bark.
	out = _out_from(tree, s.pos)
	var mid_up := s.pos - Vector3(sin(s.yaw), 0.0, cos(s.yaw)) * 0.03 * WS.M
	_frame(mid_up + out * 1.6 * WS.M + Vector3.UP * 0.4 * WS.M, mid_up)
	await _shot("squirrel_up", mid_up, 1.2)


## The horizontal unit from the tree's trunk out to pos (the side the squirrel keeps to), else
## RIGHT.
func _out_from(tree: Array, pos: Vector3) -> Vector3:
	var away := Vector3(pos.x - float(tree[0]), 0.0, pos.z - float(tree[1]))
	if away.length_squared() < 1e-12:
		return Vector3.RIGHT
	return away.normalized()


## The first squirrel spot of the grown city with free ground off it for the hero to stand on,
## {"key", "home", "tree", "stand"}, else {}.
func _squirrel_spot(sq: SQ) -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = sq.call("_spot_of", i)
		if s.is_empty():
			continue
		var home: Vector3 = s["home"]
		if ctx.collision.surface_at(home) == "asphalt" or is_nan(ctx.collision.walk_height(home)):
			continue
		var stand := _stand_off(home)
		if not stand.is_finite():
			continue
		s["stand"] = stand
		return s
	return {}


## Free walkable ground 1.0 u off home (outside the squirrel's WARY, inside the scan's FAR), else
## NAN.
func _stand_off(home: Vector3) -> Vector3:
	for k in range(12):
		var a := TAU * float(k) / 12.0
		var p := home + Vector3(cos(a), 0.0, sin(a)) * 1.0
		var h := ctx.collision.walk_height(p)
		if is_nan(h) or ctx.collision.surface_at(p) in ["asphalt", "water"]:
			continue
		if ctx.collision.is_blocked(Vector3(p.x, h, p.z), WS.PLAYER_RADIUS):
			continue
		return Vector3(p.x, h, p.z)
	return LIFE.NO_POINT


# ------------------------------------------------------------------ 4. the horn


## The hero's car horn (horn_sounded, the drive feature's street radius): the pigeons foraging on
## the sidewalk go up together and wheel over the street. Crops: the flock wheeling up.
func _horn() -> void:
	var pg: PG = f.get("pigeons")
	var fl: FLOCK = pg.flock
	var spot := _pigeon_spot(pg)
	if spot.is_empty():
		_fail("a sidewalk the pigeons keep to")
		return
	var home: Vector3 = spot["home"]
	var run: Vector3 = spot["run"]
	ctx.player.teleport(home - run * 8.0 * WS.M, 0.0)
	await _step(AF.SCAN_S + 0.2)
	var fk := _flock_of(fl, "s:%d" % int(spot["lot"]))
	if fk == null:
		_fail("the spot's pigeon flock comes out")
		return
	# The street before it: the birds foraging on the sidewalk down it.
	_frame(
		home - run * 6.0 * WS.M + Vector3.UP * 2.5 * WS.M,
		home + run * 8.0 * WS.M + Vector3.UP * 1.2 * WS.M
	)
	await _shot("horn_street")
	# The horn, from where the hero's car would be: the whole flock goes up. Shot as they lift
	# off, still bunched over their spot (half a second on they have wheeled apart), from high
	# enough to see over the parked cars at the curb.
	ctx.bus.horn_sounded.emit(Vector2(home.x, home.z), DRIVE.HORN_STREET_R, true)
	await _step(0.45)
	var up := true
	for b: FLOCK.Bird in fk.birds:
		up = up and b.air
	_check(up, "horn: the horn sends the flock up")
	var focus := home + Vector3.UP * 1.2 * WS.M
	_frame(_eye(focus, 200.0, 6.5, 3.6), focus)
	await _shot("horn_flush", focus, 4.5)


## The first sidewalk spot the pigeons keep to (a shop or civic front; pigeons.gd _spot_of()).
func _pigeon_spot(pg: PG) -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		if not PG.FRONTS.has(ctx.sim.kind[i]):
			continue
		var s: Dictionary = pg.call("_spot_of", i)
		if not s.is_empty():
			return s
	return {}


# ------------------------------------------------------------------ 5. the chase and the stalk


## A dog after a cat by a town lawn tree: the cat bolts up the trunk out of its reach and the dog
## barks up at it from where the lot's fence holds it, then gives up; then, the dog called off and
## the squirrel back on its lawn, a hunter cat creeps up on it, low and slow.
func _chase_and_stalk() -> void:
	_quiet()
	_no_dogs_at_home()
	var sq: SQ = f.get("squirrels")
	var spot := _town_spot(sq)
	if spot.is_empty():
		_fail("a town lawn with a tree (the cat's refuge)")
		return
	FeatureFlags.set_override("pigeons", false)
	(f.get("pigeons") as PG).clear()
	var cats_node: Node = f.get("cats")
	cats_node.call("clear")
	ctx.player.teleport((spot["home"] as Vector3) + Vector3(40.0 * WS.M, 0.0, 0.0), 0.0)
	await _step(AF.SCAN_S + 0.2)
	await _chase_scene(spot, cats_node)
	await _stalk_scene(spot, cats_node, (sq.get("life") as LIFE).squirrel(str(spot["key"])))
	FeatureFlags.set_override("pigeons", true)


## The dog-chases-cat scene at the spot: the dash across the lawn, then the cat clinging up the
## trunk with the dog barking below.
func _chase_scene(spot: Dictionary, cats_node: Node) -> void:
	var home: Vector3 = spot["home"]
	var tree: Array = spot["tree"]
	var trunk := Vector3(tree[0], 0.0, tree[1])
	var out := home - trunk
	out.y = 0.0
	out = out.normalized() if out.length_squared() > 1e-12 else Vector3.RIGHT
	var cat_life: CAT_LIFE = cats_node.get("life")
	var b = (cats_node.get("bodies") as Object).call("make", "cat", 1.0, cats_node)
	var d: PACK.Dog = f.call(
		"_spawn", "proof:chaser", home + out * 6.0 * WS.M, atan2(-out.x, -out.z), false, "shiba"
	)
	if b == null or d == null:
		_fail("the chase's cat and dog come out")
		return
	var c: CAT_LIFE.Cat = cat_life.add(b, home + out * 2.5 * WS.M, 0.0, Rect2())
	c.key = "proof:prey"
	c.hunter = false
	c.meow_t = 1e9
	d.temper = "friendly"
	d.chases = true
	d.chase_cool = 0.0
	pack.to_yard(d, -1, home, Rect2(home.x - 0.6, home.z - 0.6, 1.2, 1.2))
	var t := 0.0
	var dashed := false
	while t <= 4.0:
		await _step(0.1)
		t += 0.1
		if c.act == "flee" and not c.tree.is_empty() and d.act == "chase":
			dashed = true
			break
	_check(dashed, "chase: the dog after the cat, the cat bolting for its tree")
	await _step(0.3)
	var mid := (c.pos + d.pos) * 0.5 + Vector3.UP * 0.25 * WS.M
	_frame(_eye(mid, 150.0, 3.2, 1.1), mid)
	await _shot("chase_dash", mid, 3.4)
	t = 0.0
	while t <= 10.0 and c.act != "hold":
		await _step(0.2)
		t += 0.2
	_check(
		c.act == "hold" and c.climb_y >= CAT_LIFE.CLING_H - 0.005,
		"chase: the cat clings up the trunk out of the dog's reach (%s)" % c.act
	)
	await _step(1.5)
	var barked := int((f.get("calls") as Dictionary).get("bark", 0))
	_check(barked >= 1, "chase: the dog barks up at it from where it got to (%d)" % barked)
	_check(d.act != "chase" and d.chase == "", "chase: it gives up below (%s)" % d.act)
	# From the dog's side of the trunk (the way the cat came in, the side it clings to): the
	# cat pitched against the bark above, the dog at the foot of the lawn below.
	var cling := trunk + Vector3.UP * c.climb_y
	var side := Vector3(-out.z, 0.0, out.x)
	_frame(
		trunk + out * 4.0 * WS.M + side * 1.4 * WS.M + Vector3.UP * 1.3 * WS.M,
		trunk + Vector3.UP * 1.2 * WS.M
	)
	await _shot("chase_treed", cling, 3.2)
	f.call("_drop", d)
	cats_node.call("_drop", c)


## The stalk scene at the spot: with the dog gone and the squirrel back foraging, a hunter cat
## creeps up on it. s is the spot's squirrel (null: the scene is skipped).
func _stalk_scene(spot: Dictionary, cats_node: Node, s: LIFE.Squirrel) -> void:
	if s == null:
		_fail("stalk: the spot's squirrel is about")
		return
	var home: Vector3 = spot["home"]
	var tree: Array = spot["tree"]
	var trunk := Vector3(tree[0], 0.0, tree[1])
	var out := home - trunk
	out.y = 0.0
	out = out.normalized() if out.length_squared() > 1e-12 else Vector3.RIGHT
	var t := 0.0
	while t <= 14.0 and not s.state in ["forage", "nibble"]:
		await _step(0.25)
		t += 0.25
	var cat_life: CAT_LIFE = cats_node.get("life")
	var hb = (cats_node.get("bodies") as Object).call("make", "cat", 1.0, cats_node)
	if hb == null:
		_fail("stalk: the hunter's body comes out")
		return
	var h: CAT_LIFE.Cat = cat_life.add(hb, home + out * 2.5 * WS.M, 0.0, Rect2())
	h.key = "proof:hunter"
	h.hunter = true
	h.meow_t = 1e9
	h.hunt_cool = 0.0
	t = 0.0
	while t <= 6.0 and h.act != "stalk":
		await _step(0.1)
		t += 0.1
	_check(
		h.act == "stalk" and _flat(h.prey, s.pos) < 0.2 * WS.M,
		"stalk: a hunter creeps up on the squirrel (%s)" % h.act
	)
	# A beat of creeping, then the shot: the cat low, side on, the squirrel at its tree ahead.
	await _step(2.0)
	var mid := (h.pos + s.pos) * 0.5 + Vector3.UP * 0.12 * WS.M
	var along := s.pos - h.pos
	along.y = 0.0
	var side := (
		Vector3(-along.z, 0.0, along.x).normalized()
		if along.length_squared() > 1e-12
		else Vector3.RIGHT
	)
	_frame(mid + side * 2.2 * WS.M + Vector3.UP * 0.5 * WS.M, mid)
	await _shot("stalk", mid, 2.6)
	cats_node.call("_drop", h)


## The first squirrel spot NOT in the woods (a street or lot tree, whose trunk the collision
## world holds, so the cat's refuge can find it) with free ground off it, else {}.
func _town_spot(sq: SQ) -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		if ctx.sim.kind[i] == SD.FOREST:
			continue
		var s: Dictionary = sq.call("_spot_of", i)
		if s.is_empty():
			continue
		var home: Vector3 = s["home"]
		if ctx.collision.surface_at(home) == "asphalt" or is_nan(ctx.collision.walk_height(home)):
			continue
		if not _stand_off(home).is_finite():
			continue
		return s
	return {}


# ------------------------------------------------------------------ 6. night and rain


## Night: the diurnal flocks (pigeons, perched birds, ducks) roost and the dogs and the cats out
## are drawn (no invisible bodies); the house cats and the strays are about. Crops: the dog on its
## lead and the house cat, at night.
func _night() -> void:
	ctx.sky.fixed_hour = 22.0
	ctx.sky.hour = 22.0
	ctx.sky.night = 1.0
	ctx.sky.call("_apply", 1.0)
	f.on_world_rebuilt()
	_quiet()
	_no_dogs_at_home()
	var st := await _stage_walker_dog()
	var spot := _cat_spot("shop")
	if st.is_empty() or spot.is_empty():
		_fail("night: a sidewalk, a dog owner and a shop's cat spot")
		return
	var d: PACK.Dog = st[1]
	var run: Vector3 = (st[2] as Dictionary)["run"]
	# The diurnal flocks are all gone (they roost).
	var birds: int = (f.get("pigeons") as Node).flock.flocks.size()
	var perched: int = (f.get("perches") as Node).flock.flocks.size()
	var ducks: int = (f.get("waterfowl") as Node).flock.flocks.size()
	_check(birds == 0 and perched == 0 and ducks == 0, "night: the diurnal flocks roost")
	_check(d != null and _drawn(d.body), "night: the dog on its lead is drawn")
	# The dog, shot while it is still near the hero (the scan drops it once he walks off).
	if d != null:
		var hand: Vector3 = d.hand
		var collar := pack.collar_of(d)
		var mid := (hand + collar) * 0.5
		_frame(_eye(mid, 40.0, 1.8, 0.4), mid)
		await _shot("night_dog", mid, 1.8)
	await _street_shot("night_street", run)
	# The house cat: out at night too, drawn.
	ctx.player.teleport((spot["anchor"] as Vector3) + Vector3(0.4 * WS.M, 0.0, 0.0), 0.0)
	await _step(AF.SCAN_S + 0.4)
	var cat := _cat_of("c:%d" % int(spot["lot"]))
	_check(cat != null and _drawn(cat.body), "night: the house cat is out and drawn")
	if cat != null:
		var head := _cat_head(cat)
		_frame(_eye(head, 40.0, 1.6, 0.6), head)
		await _shot("night_cat", head, 1.4)


## A wide frame down the street the hero stands on (run is the sidewalk direction): the camera
## back and above him along the sidewalk, looking on down it.
func _street_shot(name: String, run: Vector3) -> void:
	var p := ctx.player.position
	var eye := p - run * 6.0 * WS.M + Vector3.UP * 3.0 * WS.M
	var focus := p + run * 8.0 * WS.M + Vector3.UP * 1.2 * WS.M
	_frame(eye, focus)
	await _shot(name)


## Rain: the cats all stay in (no z-fighting or invisible bodies on a wet street), the diurnal
## flocks and the squirrels shelter too, the dogs are fewer, and a staged dog is still drawn.
## Crops: the wet street.
func _rain() -> void:
	if streetscape == null:
		_fail("rain: the streetscape feature")
		return
	streetscape.call("force_weather", "rain")
	await _step(1.0)
	var rain := str((streetscape.get("weather") as Object).get("state")) == "rain"
	var cats: int = (_life().get("cats") as Array).size()
	var share: float = f.call("_walk_share")
	_check(rain, "rain: the streets are wet")
	_check(cats == 0, "rain: the cats stay in (%d out)" % cats)
	_check(share < AF.WALK_SHARE, "rain: fewer walk the dog (%.3f)" % share)
	# The diurnal animals shelter in the rain too (as the cats do): no pigeons, perched birds,
	# ducks or squirrels out.
	var birds: int = (f.get("pigeons") as Node).flock.flocks.size()
	var perched: int = (f.get("perches") as Node).flock.flocks.size()
	var ducks: int = (f.get("waterfowl") as Node).flock.flocks.size()
	var squirrels: int = (
		((f.get("squirrels") as Node).get("life") as Object).get("squirrels").size()
	)
	_check(
		birds == 0 and perched == 0 and ducks == 0 and squirrels == 0,
		(
			"rain: the diurnal animals shelter (%d pigeons, %d perched, %d ducks, %d squirrels)"
			% [birds, perched, ducks, squirrels]
		)
	)
	# A horn in the rain finds nothing to flush: none of the birds is out to hear it.
	ctx.bus.horn_sounded.emit(
		Vector2(ctx.player.position.x, ctx.player.position.z), DRIVE.HORN_STREET_R, true
	)
	await _step(0.5)
	_check(
		(
			(f.get("pigeons") as Node).flock.flocks.size() == 0
			and (f.get("perches") as Node).flock.flocks.size() == 0
		),
		"rain: a horn finds nothing to flush"
	)
	# A dog staged in the rain is still drawn on the wet street.
	_quiet()
	_no_dogs_at_home()
	var st := await _stage_walker_dog()
	if not st.is_empty():
		var d: PACK.Dog = st[1]
		var run: Vector3 = (st[2] as Dictionary)["run"]
		_check(d != null and _drawn(d.body), "rain: the dog is drawn on the wet street")
		if d != null:
			var mid := (d.pos as Vector3) + Vector3.UP * 0.3 * WS.M
			_frame(_eye(mid, 40.0, 2.2, 0.5), mid)
			await _shot("rain_dog", mid, 2.0)
		await _street_shot("rain_street", run)
	# A closer frame on the hero's own footing on the wet street, no birds about it.
	var foot := ctx.player.position + Vector3.UP * 0.5 * WS.M
	_frame(_eye(foot, 40.0, 3.2, 1.2), foot)
	await _shot("rain_near", foot, 4.0)
	streetscape.call("clear_forced_weather")


## True when b's root is in the scene and its visual position is where the body stands (no
## invisible or mis-placed body).
func _drawn(b: BODIES.Body) -> bool:
	return b != null and b.root != null and b.root.is_inside_tree() and b.root.is_visible_in_tree()


## The first cat spot of kind in the grown city, else {}.
func _cat_spot(kind: String) -> Dictionary:
	var cats: Object = f.get("cats")
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = cats.call("_spot_of", i, {})
		if not s.is_empty() and str(s["kind"]) == kind:
			return s
	return {}


func _cat_of(key: String) -> Object:
	for c: Object in _life().get("cats") as Array:
		if str(c.get("key")) == key:
			return c
	return null


## The cats node's life (cat_life.gd): the cats out.
func _life() -> Object:
	return (f.get("cats") as Node).get("life")


func _cat_head(c: Object) -> Vector3:
	var b: BODIES.Body = c.get("body")
	if b != null and b.skel != null and b.skel.is_inside_tree():
		var k := b.skel.find_bone("Head")
		if k >= 0:
			return b.skel.global_transform * b.skel.get_bone_global_pose(k).origin
	return (c.get("pos") as Vector3) + Vector3.UP * 0.15 * WS.M


## Prints and records the result of a check.
func _check(ok: bool, what: String) -> void:
	print("WILDLIFE_PROOF: %s %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		failed = true


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
