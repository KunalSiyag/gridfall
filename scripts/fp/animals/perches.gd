extends "res://scripts/fp/animals/bird_flocks.gd"
## The perched birds (part of the animals feature): pigeons that keep to the high perches by day,
## the same bird and behaviour as the sidewalk flocks (pigeon_body.gd, pigeon_flock.gd), the flock
## wiring shared with them (bird_flocks.gd). A share of the street lamps keeps one bird on its
## top, and a share of the built lots a row along the roof edge of its tallest block facing the
## road, all deterministic from the city seed. They sit, preen and turn on their perches above the
## passing street — people, cars and the hero below never stir them — and only a fright on the
## street itself, a shout, a blow, a dog barking or a crash, sends them up with a clatter to wheel
## over the roofs and glide back onto their perches. Their coos go out on the bus (animal_called).
## The flag off takes them away (the flocks, not the spots).

## Perched flocks come out within NEAR of the player (u) and go beyond FAR, at most MAX_PERCHES
## of them (one a lamp, one a roof edge) at once.
const NEAR := 3.0
const FAR := 3.6
const MAX_PERCHES := 3
## This share of a lot's kind keeps a row on its roof edge; a plain home's share of that again.
const ROOF_SHARES := {
	D.HALL: 1.0,
	D.TRAIN: 1.0,
	D.STADIUM: 0.6,
	D.UNIVERSITY: 0.6,
	D.SCHOOL: 0.4,
	D.ZONE_C: 0.4,
	D.ZONE_I: 0.3,
	D.ZONE_R: 0.4,
}
## A roof edge keeps ROOF_N birds at most along it, EDGE_STEP (u) apart, on the edge of the
## roof's tallest block (a block at least MIN_BLOCK (u) each way) facing the lot's road. The birds
## stand on the horizontal roof top, inset ROOF_INSET (u) from the lip so they are never left on
## the wall face: the roof is the block's own top, raised to the model's top when that stands only
## ROOF_LIFT_MAX (u) prouder of it (a parapet or coping; a tower or spire is left out of it).
const ROOF_N := Vector2i(2, 5)
const EDGE_STEP := 0.09
const MIN_BLOCK := 0.12
const ROOF_INSET := 0.02
const ROOF_LIFT_MAX := 0.06
## This share of the street lamps keeps a bird on the top.
const LAMP_SHARE := 0.35
## A lamp to perch on: a prop cylinder of about a lamp pole's radius whose top stands LAMP_Y (u)
## or more over the street (a hydrant or a low post is no perch), and not above LAMP_TOP (u).
const LAMP_R := Vector2(0.007, 0.009)
const LAMP_Y := 0.12
const LAMP_TOP := 0.5
## The hero's swings, shove, shout, dance and parkour moves send the perched birds up within these
## (m); someone hit in the street those within SEEN_HIT, a dog's bark those within BARK_M, a crash
## those within CRASH_M and a prop knocked over those within KNOCK_M.
const STARTLE := {
	"jab": 3.0,
	"cross": 3.0,
	"hook": 3.0,
	"kick": 3.0,
	"swing": 3.0,
	"shove": 3.0,
	"dance": 3.0,
	"shout": 10.0,
	"vault": 3.0,
	"hop": 3.0,
	"climb": 3.0,
	"roll": 3.0,
	"run_up": 3.0,
	"catch": 3.0,
	"leap": 3.0,
	"hijack": 3.0,
}
const SEEN_HIT := 6.0
const BARK_M := 5.0
const CRASH_M := 20.0
const KNOCK_M := 6.0


func setup(p_ctx: FpContext) -> void:
	setup_flocks(p_ctx)
	name = "Perches"


## Every scan (bird_flocks.gd scan_flocks()): the perched flocks too far off go; in the rain they
## all stay in (they shelter); else by day (and with the flag on) the lamp and roof-edge spots near
## me get theirs, the nearest first.
func scan(me: Vector3, by_day: bool, rain := false) -> void:
	var on := by_day and not rain and FeatureFlags.enabled("perched_birds")
	scan_flocks(me, on, MAX_PERCHES, NEAR, FAR, rain)


## dt game seconds of the perched flocks (bird_flocks.gd step_flocks()). The flag off takes them
## away.
func step(dt: float) -> void:
	step_flocks(dt, FeatureFlags.enabled("perched_birds"))


func on_crash(at: Vector3, _speed: float, _what: String) -> void:
	startle(at, CRASH_M)


func on_knock(at: Vector3, _kind: String, _speed: float) -> void:
	startle(at, KNOCK_M)


## Self-test line: how many birds sit perched in how many flocks.
func detail() -> String:
	var n := 0
	for f: FLOCK.Flock in flock.flocks:
		n += f.birds.size()
	return "%d perched in %d flocks" % [n, flock.flocks.size()]


# ------------------------------------------------------------------ spots


## Tile i's perch spot: {"key", "home" (the middle of the points), "points" (one a bird)}, or {}
## for none (a lamp of the street, a roof edge of a built lot; the hall is always built).
func _spot_of(i: int) -> Dictionary:
	if _spots.has(i):
		return _spots[i]
	var out := {}
	if ctx.collision != null:
		var k := ctx.sim.kind[i]
		if k == D.ROAD:
			out = _lamp_spot(i)
		elif ROOF_SHARES.has(k) and (ctx.sim.level[i] > 0 or k == D.HALL):
			out = _roof_spot(i)
	_spots[i] = out
	return out


## The first lamp of the street tile whose roll keeps a bird on its top: the lamp poles the
## collision world knows as thin cylinders standing high over the street, one bird at the top.
func _lamp_spot(i: int) -> Dictionary:
	var cy := ctx.collision.cylinders(i)
	for k in range(0, cy.size(), 4):
		var r := cy[k + 2]
		var top := cy[k + 3]
		if r < LAMP_R.x or r > LAMP_R.y or top < LAMP_Y or top > LAMP_TOP:
			continue
		if _roll("lamp:%d:%d" % [i, k]) >= LAMP_SHARE:
			continue
		var p := Vector3(cy[k], top, cy[k + 1])
		return {"key": "lamp:%d:%d" % [i, k], "home": p, "points": PackedVector3Array([p])}
	return {}


## The roof edge of lot i's tallest block facing its road: a row of points along it, or {} for
## none (no road in front, no block big enough, the edge too short for two birds). Every point
## stands on the block's horizontal roof top, inset ROOF_INSET from the lip (raised to the model's
## top only when that is a parapet or coping, ROOF_LIFT_MAX proud), so no bird is left on the wall
## face of a facade or a ledge band.
func _roof_spot(i: int) -> Dictionary:
	if _roll("roof:%d" % i) >= float(ROOF_SHARES.get(ctx.sim.kind[i], 0.0)):
		return {}
	var fr := ctx.directory.frontage(i) if ctx.directory != null else -1
	if fr < 0:
		return {}
	var top := AABB()
	for b: AABB in ctx.collision.body_boxes(i):
		if b.size.x < MIN_BLOCK or b.size.z < MIN_BLOCK:
			continue
		if top.size.x <= 0.0 or b.end.y > top.end.y:
			top = b
	if top.size.x <= 0.0:
		return {}
	var roof := top.end.y
	var model := ctx.view.building_aabb(i).end.y if ctx.view != null else roof
	if model > roof and model - roof <= ROOF_LIFT_MAX:
		roof = model
	var road := _tile_pos(fr) - _tile_pos(i)
	var dir := Vector3(road.x, 0.0, road.z).normalized()
	var side_x := absf(dir.x) > absf(dir.z)
	var run := Vector3.BACK if side_x else Vector3.RIGHT
	var edge := top.get_center()
	if side_x:
		edge.x = top.end.x if dir.x > 0.0 else top.position.x
	else:
		edge.z = top.end.z if dir.z > 0.0 else top.position.z
	edge.y = roof
	var span := top.size.z if side_x else top.size.x
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("perch:%d" % i) ^ (ctx.sim.city_seed * 7919)
	var n := mini(rng.randi_range(ROOF_N.x, ROOF_N.y), int(span / EDGE_STEP) + 1)
	if n < ROOF_N.x:
		return {}
	var inward := Vector3(-dir.x, 0.0, -dir.z) * ROOF_INSET
	var points := PackedVector3Array()
	for k in range(n):
		points.append(edge + run * ((float(k) - (n - 1) * 0.5) * EDGE_STEP) + inward)
	return {"key": "roof:%d" % i, "home": points[points.size() / 2], "points": points}


# ------------------------------------------------------------------ flocks


## The spot's flock perched on its points (bird_flocks.gd add_perched()), drawn at once.
func _make(key: String, s: Dictionary) -> FLOCK.Flock:
	var f := flock.add_perched(key, s["points"])
	_make_node(f)
	return f


## A number in [0, 1) that stays the same for key in this city.
func _roll(key: String) -> float:
	return float(absi(hash("%s:%d" % [key, ctx.sim.city_seed])) % 10000) / 10000.0


static func _tile_pos(i: int) -> Vector3:
	return Vector3(D.tx(i), 0.0, D.ty(i))
