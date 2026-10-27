extends RefCounted
## The residents' own parked cars (trips.gd): each resident's car is made once and parked near
## their lot between trips, an out-of-sight decor car giving up its slot for it, and the parked
## table is the save's record of who sits where. The cars dictionary is trips.gd's own, shared.

const D := preload("res://scripts/sim/sim_defs.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")

var f: Object  # the traffic feature (models, door points, visibility)
var people: Residents
var lg: LG
var vh: VH
## trips.gd's rid -> Car, shared (trips clears it on a new world, never reassigns it).
var cars: Dictionary


func _init(p_f: Object, p_people: Residents, p_lg: LG, p_vh: VH, p_cars: Dictionary) -> void:
	f = p_f
	people = p_people
	lg = p_lg
	vh = p_vh
	cars = p_cars


## The resident's own car, creating it (parked near lot, facing road tile `toward` when given) the
## first time.
func car_of(rid: String, lot: int, toward: int = -1) -> VH.Car:
	var c: VH.Car = cars.get(rid, null)
	if c != null and not c.dead:
		return c
	var m: int = f.car_model_for(rid)
	if m < 0:
		return null
	c = vh.make("car", "resident", f.dims(m))
	c.model = m
	c.driver_id = rid
	cars[rid] = c
	if not park_near(c, lot, -1, toward):
		c.parked = true
		c.slot_tile = -1
		c.pos = f.door_point(lot)
	return c


## Parks c in a free slot near lot's frontage (facing road tile `toward` first, then the lot's
## side), or near tile `road`. With `toward`, the tiles further along that way are tried before
## the wrong side, and an out-of-sight decor car may give up its slot.
func park_near(c: VH.Car, lot: int, road: int, toward: int = -1) -> bool:
	var fr: int = road if road >= 0 else (f.ctx.directory.frontage(lot) if lot >= 0 else -1)
	if fr < 0:
		return false
	var cand: Array[int] = [fr]
	if toward >= 0:
		var step := Vector2i(D.tx(toward) - D.tx(fr), D.ty(toward) - D.ty(fr))
		if step != Vector2i.ZERO and absi(step.x) + absi(step.y) == 1:
			for k in range(1, 3):
				var x := D.tx(fr) + step.x * k
				var y := D.ty(fr) + step.y * k
				if D.in_bounds(x, y) and lg.tiles.has(D.idx(x, y)):
					cand.append(D.idx(x, y))
		elif toward != fr:
			cand.append(toward)
	for n: int in lg.neighbours(fr):
		if not cand.has(n):
			cand.append(n)
	var own := "car:%d" % c.id
	for pass_i in range(2 if toward >= 0 else 1):
		for i: int in cand:
			if not lg.parkable(i):
				continue
			var rd := lg.run_dir(i)
			var ks: Array[int] = [0, 1, 2, 3]
			if toward >= 0:
				var go := Vector2(D.tx(toward) - D.tx(i), D.ty(toward) - D.ty(i))
				if go == Vector2.ZERO:
					go = Vector2(D.tx(toward) - D.tx(fr), D.ty(toward) - D.ty(fr))
				var side := 0 if rd.dot(go) >= 0.0 else 1
				# First pass: only the side facing the route; second pass: the other side.
				var sd := side if pass_i == 0 else 1 - side
				ks = [sd * 2, sd * 2 + 1]
			elif lot >= 0:
				var to_lot := Vector2(D.tx(lot) - D.tx(i), D.ty(lot) - D.ty(i))
				var lot_side := 0 if Vector2(-rd.y, rd.x).dot(to_lot) > 0.0 else 1
				ks = [lot_side * 2, lot_side * 2 + 1, (1 - lot_side) * 2, (1 - lot_side) * 2 + 1]
			for k: int in ks:
				if not lg.slot_valid(i, k):
					continue
				var owner := lg.slot_owner(i, k)
				if (
					owner.is_empty()
					or owner == own
					or (pass_i == 0 and toward >= 0 and evict_decor(i, k))
				):
					vh.park_at(c, i, k)
					return true
	return false


## Removes the decor car in slot (i, k) when it is out of sight. True when the slot is now free.
func evict_decor(i: int, k: int) -> bool:
	for d: VH.Car in vh.cars:
		if d.parked and d.role == "decor" and d.slot_tile == i and d.slot_k == k:
			if f.on_screen(d.pos):
				return false
			vh.remove(d)
			return lg.slot_free(i, k)
	return false


## Saved parked table: {rid: [tile, slot]}.
func parked_table() -> Dictionary:
	var out := {}
	for rid: String in cars.keys():
		var c: VH.Car = cars[rid]
		if c.parked and c.slot_tile >= 0 and not c.dead:
			out[rid] = [c.slot_tile, c.slot_k]
	return out


## Restores parked cars from a saved table (only for residents who still exist).
func restore_parked(d: Dictionary) -> void:
	for key: Variant in d.keys():
		var rid := str(key)
		var v: Variant = d[key]
		if typeof(v) != TYPE_ARRAY or (v as Array).size() < 2 or people.find(rid).is_empty():
			continue
		var i := int(v[0])
		var k := int(v[1])
		var m: int = f.car_model_for(rid)
		if m < 0:
			continue
		var c: VH.Car = cars.get(rid, null)
		if c == null:
			c = vh.make("car", "resident", f.dims(m))
			c.model = m
			c.driver_id = rid
			cars[rid] = c
		# The saved car's own slot back: the decor car that took it gives way (owned cars keep it).
		if (
			lg.slot_valid(i, k)
			and (lg.slot_free(i, k) or lg.slot_owner(i, k) == "car:%d" % c.id or evict_decor(i, k))
		):
			vh.park_at(c, i, k)
		else:
			park_near(c, -1, i)
		c.state = "parked"
