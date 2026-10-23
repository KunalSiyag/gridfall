extends FpFeature
## Dogs in the street (integration feature "animals"). Some people out on foot walk a dog on a
## lead: residents whose household lives with a dog (unless they are off to work) and a share of
## everyone else, fewer at night and in the rain. A dog household's dog keeps to the front yard
## of its house while nobody walks it, and a resident coming out takes it along. The dogs
## (dog_pack.gd) heel, stop to sniff, roam round an owner who stands still, come over to a
## crouching hero, bark at the hero and at people going by, flinch at blows and shouts, defend an
## owner the hero hits (biting: hero_hit "bite") and leap clear of cars. E pets a dog close by.
## Their barks, growls and whines go out on the bus (animal_called) for the audio feature. The
## bodies are Shiba Inus and huskies (dog_bodies.gd) with leads from the owner's hand to the collar
## (dog_leads.gd). Motion runs on delta * sim.speed, so pause freezes it.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const BODIES := preload("res://scripts/fp/animals/dog_bodies.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")
const LEADS := preload("res://scripts/fp/animals/dog_leads.gd")

const MAX_STEP := 1.0 / 30.0
## Dogs come out within NEAR of the player (u, about their draw distance) and go beyond FAR, at
## most MAX_DOGS at a time. Owners and yards are looked over every SCAN_S (s), the dog households
## every HOMES_S.
const NEAR := 3.0
const FAR := 3.6
const MAX_DOGS := 10
const SCAN_S := 0.5
const HOMES_S := 10.0
## Share of the people out on foot who walk a dog, and what the night (sky.night above NIGHT)
## and the rain leave of it.
const WALK_SHARE := 0.08
const NIGHT := 0.5
const NIGHT_K := 0.4
const RAIN_K := 0.25
const DOG_HOUSEHOLD := "lives with a dog"
## A resident on these errands leaves the dog at home.
const NO_DOG_STATES: Array[String] = ["work", "working late"]
## Front yards: houses up to YARD_LEVEL keep their dog in front. Its spot is looked for
## YARD_DEPTHS tiles from the middle of the lot toward the road and YARD_SIDES to the side, and it
## keeps to YARD_BOX (tiles toward the road from x to y, z to each side).
const YARD_LEVEL := 2
const YARD_DEPTHS: Array[float] = [0.38, 0.32, 0.44]
const YARD_SIDES: Array[float] = [0.0, 0.18, -0.18, 0.34, -0.34]
const YARD_BOX := Vector3(0.24, 0.48, 0.46)
## A dog whose owner left the street goes after them this long after (game s).
const LOST_S := 2.5
## E pets a dog within PET_REACH of the eyes that nothing hides (OCCLUDE before it).
const PET_REACH := 2.4 * WS.M
const OCCLUDE := 0.3 * WS.M
## The hero's swings, shove and shout startle the dogs within these (m); someone hit startles
## the dogs within SEEN_HIT (m) and a wave cheers the friendly ones within WAVE_AT.
const STARTLE := {"jab": 3.0, "cross": 3.0, "shove": 3.0, "shout": 7.0}
const SEEN_HIT := 8.0
const WAVE_AT := 6.0 * WS.M
## A bite's hero_hit strength and push (u/s).
const BITE := 0.25
const BITE_PUSH := 0.6 * WS.M
## Leads further than this from the camera are not drawn (u).
const LEAD_VIS := 2.0
## Moving vehicles' half length and half width (m) for the dogs' dodge.
const BIG_VEHICLE := Vector2(6.0, 1.3)
const CAR := Vector2(2.3, 1.0)
## Dogs' names, a he's and a she's (space-separated).
const HE_NAMES := "Biscuit Kuma Rex Bruno Max Rocky Bear Scout Ziggy Hachi Mochi Pepper"
const SHE_NAMES := "Luna Daisy Maple Hazel Olive Nala Juno Sasha Pixie Koda Willow Suki"
const BREED_NAMES := {"shiba": "Shiba Inu", "husky": "husky"}
## The photo shot stands PHOTO_BACK (tiles) from the middle of the lot toward the road, looking
## PHOTO_PITCH (degrees) down at its dogs, which stand PHOTO_DEPTH toward the road when the ground
## there is free.
const PHOTO_BACK := 0.62
const PHOTO_PITCH := -20.0
const PHOTO_DEPTH := 0.45

var bodies: BODIES
var pack: PACK
var leads: LEADS
## The dogs live on game time even with the sim paused (the photo tour).
var live: bool = false
var pets: int = 0
var bites: int = 0
## Calls made so far by kind ("bark", "growl", "whine").
var calls: Dictionary = {}
var _root: Node3D
var _scan_t: float = 0.0
var _homes_t: float = 0.0
## The dog households: [resident id, home lot].
var _homes: Array = []
## Walker id -> whether they walk a dog (people passing through, decided when first seen).
var _decided: Dictionary = {}
## Lot -> its front yard (_yard()), {} for none.
var _yards: Dictionary = {}
## The photo shot's {"lot", "yard"}, {} without one.
var _photo: Dictionary = {}


func feature_id() -> String:
	return "animals"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	bodies = BODIES.new()
	bodies.check()
	bodies.start()
	pack = PACK.new()
	pack.col = ctx.collision
	pack.on_call = _on_call
	pack.on_bite = _on_bite
	_root = Node3D.new()
	_root.name = "Dogs"
	add_child(_root)
	leads = LEADS.new()
	add_child(leads)
	if ctx.bus != null:
		link_signal(ctx.bus.interact_requested, _on_interact)
		link_signal(ctx.bus.person_hit, _on_person_hit)
		link_signal(ctx.bus.hero_action, _on_hero_action)
	if ctx.view != null:
		link_signal(ctx.view.tile_built, _on_tile_built)


## Boot, load or New City: no dogs until the next scan finds their owners and yards.
func on_world_rebuilt() -> void:
	_clear()
	pack.col = ctx.collision
	_yards.clear()
	_decided.clear()
	_homes_t = 0.0
	_scan_t = 0.0


func teardown() -> void:
	unlink_signals()
	_clear()
	if bodies != null:
		bodies.finish_loads()
		bodies.clear()


func _notification(what: int) -> void:
	# Quitting frees the tree without teardown, and released bodies are out of the tree.
	if what == NOTIFICATION_PREDELETE and bodies != null:
		bodies.clear()


func self_test() -> Dictionary:
	var looks := "Shiba Inus and huskies" if bodies.ok else "stand-ins (%s)" % bodies.why
	var walked := 0
	for d: PACK.Dog in pack.dogs:
		if d.walker >= 0:
			walked += 1
	var out := "%s, %d dogs out (%d on leads)" % [looks, pack.dogs.size(), walked]
	return {"ok": leads != null and is_instance_valid(leads), "detail": out}


## The dog nearest along the ray within PET_REACH of the eyes that nothing hides: {"kind": "dog",
## "id", "tile", "pos" (its back), "dist", "label", "data": {"breed", "owner" (resident id)}}, or
## {}.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	if pack == null or ctx.player == null:
		return {}
	var head := ctx.player.eye_position()
	var d := dir.normalized()
	var best: PACK.Dog = null
	var bt := max_dist
	for dog: PACK.Dog in pack.dogs:
		var c := _back(dog)
		if c.distance_to(head) > PET_REACH:
			continue
		var t := _ray_ball(origin, d, c, 0.75 * pack.shoulder_m(dog) * WS.M)
		if t >= 0.0 and t < bt:
			bt = t
			best = dog
	if best == null or _hidden(origin, d, bt):
		return {}
	var at := _back(best)
	return {
		"kind": "dog",
		"id": str(best.id),
		"tile": ctx.collision.tile_at(at) if ctx.collision != null else -1,
		"pos": at,
		"dist": bt,
		"label": "Pet %s, %s" % [best.name, _whose(best)],
		"data": {"breed": best.breed, "owner": best.owner_rid},
	}


## One shot ("dogs"): a Shiba Inu and a husky in the front yard of the house nearest the player
## with room for them, seen from the sidewalk; photo_prepare lets them out.
func photo_shots() -> Array:
	_photo = _photo_yard()
	if _photo.is_empty():
		return []
	var lot := int(_photo["lot"])
	var pos := _photo_spot(lot)
	var look: Vector3 = (_photo["at"] as Vector3) - pos
	var shot := {"name": "dogs", "pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.z))}
	shot.merge({"pitch": PHOTO_PITCH, "hour": 10.0})
	shot.merge({"prepare": "photo_prepare", "restore": "photo_restore"})
	return [shot]


## Photo tour: the two dogs in the yard of the shot, standing side by side and living on game time
## with the sim paused.
func photo_prepare() -> void:
	if _photo.is_empty():
		return
	live = true
	bodies.blocking = true
	var lot := int(_photo["lot"])
	var y: Dictionary = _photo["yard"]
	var road := _tile_pos(ctx.directory.frontage(lot)) - _tile_pos(lot)
	var side := Vector3(-road.z, 0.0, road.x)
	for k in range(2):
		var at: Vector3 = (_photo["at"] as Vector3) + side * (0.05 if k == 0 else -0.05)
		var d := _spawn("photo:%d" % k, at, float(y["yaw"]), true, "shiba" if k == 0 else "husky")
		if d == null:
			continue
		d.temper = "friendly"
		d.happy = 0.8
		pack.to_yard(d, lot, at, y["box"])
		d.goal_t = 1e9
	for _k in range(3):
		_feed(MAX_STEP, 1.0)
		pack.step(MAX_STEP)


func photo_restore() -> void:
	live = false
	bodies.blocking = false
	for d: PACK.Dog in pack.dogs.duplicate():
		if d.key.begins_with("photo:"):
			_drop(d)


func _process(delta: float) -> void:
	tick(delta)


## One frame of delta real seconds (_process; tests call it with processing off).
func tick(delta: float) -> void:
	if ctx == null or ctx.sim == null or pack == null:
		return
	var speed := 1.0 if live else float(ctx.sim.speed)
	var dt := delta * speed
	if dt > 0.0:
		_scan_t -= delta
		if _scan_t <= 0.0:
			_scan_t = SCAN_S
			_scan()
	_feed(dt, speed)
	if dt <= 0.0:
		pack.step(0.0)
	var left := dt
	while left > 0.0:
		var h := minf(left, MAX_STEP)
		pack.step(h)
		left -= h
	_draw_leads()


# ------------------------------------------------------------------ bus


func _on_interact(t: Dictionary) -> void:
	if str(t.get("kind", "")) != "dog":
		return
	var d := _dog(str(t.get("id", "")).to_int())
	if d == null:
		return
	var was := d.temper
	if pack.pet(d):
		pets += 1
		var line := "%s wags %s tail and hops up. Good %s!"
		_toast(line % [d.name, "his" if d.he else "her", "boy" if d.he else "girl"], "chat")
		Analytics.track("dog_pet", {"breed": d.breed, "temper": was})
	else:
		_toast("%s growls at you. Leave %s be." % [d.name, "him" if d.he else "her"], "info")


## Someone hit in the street: their dog defends them from the hero's fists (a car only startles
## it), and the dogs around who saw it flinch.
func _on_person_hit(at: Vector3, cause: String, info: Dictionary) -> void:
	var wid := int(info.get("walker", -1))
	for d: PACK.Dog in pack.dogs:
		if wid >= 0 and d.walker == wid and cause in ["punch", "shove"]:
			if d.angry <= 0.0:
				_toast("%s goes for you!" % d.name, "info")
			pack.defend(d)
		elif _flat(d.pos, at) < SEEN_HIT * WS.M:
			pack.startle(d, at)


## The hero's swings, shove and shout startle the dogs close by; a wave cheers friendly ones.
func _on_hero_action(action: String, at: Vector3) -> void:
	if action == "wave":
		for d: PACK.Dog in pack.dogs:
			if d.temper == "friendly" and d.angry <= 0.0 and _flat(d.pos, at) < WAVE_AT:
				d.happy = maxf(d.happy, 0.7)
		return
	if not STARTLE.has(action):
		return
	var r := float(STARTLE[action]) * WS.M
	for d: PACK.Dog in pack.dogs:
		if _flat(d.pos, at) < r:
			pack.startle(d, at)


func _on_tile_built(i: int, _holder: Node3D) -> void:
	_yards.erase(i)


func _on_call(d: PACK.Dog, call: String) -> void:
	calls[call] = int(calls.get(call, 0)) + 1
	if ctx.bus != null:
		ctx.bus.animal_called.emit(pack.head_of(d), call, pack.shoulder_m(d))


func _on_bite(d: PACK.Dog) -> void:
	bites += 1
	var push := pack.hero - d.pos
	push.y = 0.0
	push = push.normalized() * BITE_PUSH if push.length_squared() > 1e-12 else Vector3.ZERO
	if ctx.bus != null:
		ctx.bus.hero_hit.emit(pack.head_of(d), "bite", BITE, push)


# ------------------------------------------------------------------ the world each frame


## The world for this frame: the hero, the traffic around and where the owners are now.
func _feed(dt: float, speed: float) -> void:
	var p := ctx.player
	var on := p != null and is_instance_valid(p) and not p.photo_mode and not _driving()
	pack.hero_on_foot = on
	pack.hero = p.position if on else Vector3(INF, INF, INF)
	pack.hero_vel = p.velocity if on else Vector3.ZERO
	pack.crouched = on and p.crouched
	pack.hero_open = on and p.input_enabled and ctx.feature("health") != null
	pack.time_scale = speed
	pack.cars.clear()
	pack.passers.clear()
	var tr := ctx.feature("traffic")
	if tr == null or pack.dogs.is_empty():
		return
	_read_traffic(tr)
	_owners_now(tr, dt)


## Moving vehicles (for the dodge) and the people going by around the player.
func _read_traffic(tr: FpFeature) -> void:
	var pk: Dictionary = tr.call("agents_packed", ctx.player_position(), FAR + 1.0)
	var pos: PackedVector3Array = pk["pos"]
	var vel: PackedVector3Array = pk["vel"]
	var kind: PackedStringArray = pk["kind"]
	for k in range(pos.size()):
		if kind[k] == "pedestrian":
			pack.passers.append(pos[k])
		else:
			var big := kind[k] == "bus" or kind[k] == "truck"
			var half := (BIG_VEHICLE if big else CAR) * WS.M
			pack.cars.append([pos[k], vel[k], half.x, half.y])


## Where every owner is now; a dog whose owner has been off the street LOST_S goes after them.
func _owners_now(tr: FpFeature, dt: float) -> void:
	var ids: Array = []
	for d: PACK.Dog in pack.dogs:
		if d.walker >= 0:
			ids.append(d.walker)
	if ids.is_empty():
		return
	var by: Dictionary = tr.call("walkers_by_id", ids)
	for d: PACK.Dog in pack.dogs.duplicate():
		if d.walker < 0:
			continue
		if by.has(d.walker):
			d.lost = 0.0
			pack.follow(d, by[d.walker], dt)
			continue
		d.lost += dt
		d.owner_vel = Vector3.ZERO
		d.hand = Vector3.INF
		if d.lost >= LOST_S:
			_owner_gone(d)


## A resident's dog goes back to its yard when its home is near; any other dog goes in after its
## owner.
func _owner_gone(d: PACK.Dog) -> void:
	var y := {}
	if d.home >= 0 and _flat(_tile_pos(d.home), ctx.player_position()) < FAR:
		y = _yard(d.home)
	if y.is_empty():
		_drop(d)
	else:
		pack.to_yard(d, d.home, y["anchor"], y["box"])


func _draw_leads() -> void:
	var cam := _camera_pos()
	var near: Array = []
	for l: Array in pack.leads():
		if (l[1] as Vector3).distance_to(cam) < LEAD_VIS:
			near.append(l)
	leads.draw(near, cam)


# ------------------------------------------------------------------ who has a dog


## Every SCAN_S: the dogs too far off go; owners and front yards near the player get theirs.
func _scan() -> void:
	var me := ctx.player_position()
	for d: PACK.Dog in pack.dogs.duplicate():
		if _flat(d.pos, me) > FAR and not d.key.begins_with("photo:"):
			_drop(d)
	_homes_t -= SCAN_S
	if _homes_t <= 0.0:
		_homes_t = HOMES_S
		_read_homes()
	var tr := ctx.feature("traffic")
	if tr != null:
		_walkers(tr, me)
	if _night() <= NIGHT and not _raining():
		_yard_dogs(me)


func _read_homes() -> void:
	_homes.clear()
	if ctx.residents == null:
		return
	for r: Dictionary in ctx.residents.people:
		if str(r.get("household", "")) == DOG_HOUSEHOLD:
			_homes.append([str(r["id"]), int(r["home"])])


## People on foot near the player who walk a dog get it at their side.
func _walkers(tr: FpFeature, me: Vector3) -> void:
	var seen := {}
	for e: Dictionary in tr.call("walkers_near", me, NEAR):
		var wid := int(e["id"])
		seen[wid] = true
		if _dog_of_walker(wid) != null or bool(e["down"]):
			continue
		var rid := str(e["resident_id"])
		if not rid.is_empty():
			var r := ctx.residents.find(rid) if ctx.residents != null else {}
			if _walks_dog(r):
				_walk_with(e, "r:" + rid, r)
			continue
		if not _decided.has(wid):
			var hands := int(e.get("extra", 0)) != 1
			_decided[wid] = hands and _roll("w:%d" % wid) < _walk_share()
		if _decided[wid]:
			_walk_with(e, "w:%d" % wid, {})
	for k: Variant in _decided.keys():
		if not seen.has(k):
			_decided.erase(k)


func _walks_dog(r: Dictionary) -> bool:
	if r.is_empty() or str(r.get("household", "")) != DOG_HOUSEHOLD:
		return false
	var st := str(r.get("state", ""))
	return st not in NO_DOG_STATES and not st.begins_with("protest")


## The dog of key (out of its yard when it is there) on the lead of the person e (walkers_near)
## describes, resident r ({} for someone passing through).
func _walk_with(e: Dictionary, key: String, r: Dictionary) -> void:
	var d := _dog_of(key)
	if d == null:
		var yaw := float(e["yaw"])
		var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
		var left := Vector3(fwd.z, 0.0, -fwd.x)
		var at: Vector3 = (e["pos"] as Vector3) + (left * 0.5 - fwd * 0.2) * WS.M
		d = _spawn(key, at, yaw, false)
		if d == null:
			return
	d.owner_rid = str(r.get("id", ""))
	d.owner_name = str(r.get("name", "")).get_slice(" ", 0)
	d.home = int(r.get("home", -1))
	pack.to_owner(d, int(e["id"]))
	pack.follow(d, e, 0.0)


## Dog households near the player whose dog nobody walks keep it in the front yard.
func _yard_dogs(me: Vector3) -> void:
	for h: Array in _homes:
		if pack.dogs.size() >= MAX_DOGS:
			return
		var lot := int(h[1])
		var key := "r:" + str(h[0])
		if _flat(_tile_pos(lot), me) > NEAR or _dog_of(key) != null:
			continue
		var y := _yard(lot)
		if y.is_empty():
			continue
		var d := _spawn(key, y["anchor"], float(y["yaw"]), true)
		if d == null:
			continue
		var r := ctx.residents.find(str(h[0]))
		d.owner_rid = str(h[0])
		d.owner_name = str(r.get("name", "")).get_slice(" ", 0)
		d.home = lot
		pack.to_yard(d, lot, y["anchor"], y["box"])


## A new dog for key at at facing yaw (a yard dog barks more often), of breed or one picked by
## key; null while its body still loads or with MAX_DOGS out.
func _spawn(key: String, at: Vector3, yaw: float, yard: bool, breed := "") -> PACK.Dog:
	if pack.dogs.size() >= MAX_DOGS:
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ (ctx.sim.city_seed * 7919)
	var pick_breed := "husky" if rng.randf() < 0.4 else "shiba"
	var size := rng.randf_range(0.92, 1.08)
	var b := bodies.make(breed if not breed.is_empty() else pick_breed, size, _root)
	if b == null:
		return null
	if ctx.collision != null:
		var y := ctx.collision.walk_height(at)
		if not is_nan(y):
			at.y = y
	var d := pack.add(b, at, yaw)
	d.key = key
	d.size = size
	d.he = rng.randf() < 0.5
	var names := (HE_NAMES if d.he else SHE_NAMES).split(" ")
	d.name = names[rng.randi() % names.size()]
	var barky := 0.45 if yard else 0.22
	var t := rng.randf()
	d.temper = "barky" if t < barky else ("shy" if t < barky + 0.15 else "friendly")
	b.root.position = at
	b.root.rotation = Vector3(0.0, yaw, 0.0)
	BODIES.play(b, d.idle, 1.0)
	return d


## Lot's front yard: {"anchor" (a free spot), "box" (Rect2 in xz), "yaw" (facing the road)}, or
## {} for none (no road in front, not a house, no free ground in front of it).
func _yard(lot: int) -> Dictionary:
	if _yards.has(lot):
		return _yards[lot]
	var out := {}
	var fr := ctx.directory.frontage(lot) if ctx.directory != null else -1
	var lv := ctx.sim.level[lot]
	var house := ctx.sim.kind[lot] == D.ZONE_R and lv > 0 and lv <= YARD_LEVEL
	if fr >= 0 and house and ctx.collision != null:
		var c := _tile_pos(lot)
		var road := _tile_pos(fr) - c
		var side := Vector3(-road.z, 0.0, road.x)
		var spot := _free_spot(c, road, side)
		if not is_nan(spot.x):
			var a := c + road * YARD_BOX.x - side * YARD_BOX.z
			var b := c + road * YARD_BOX.y + side * YARD_BOX.z
			var lo := Vector2(minf(a.x, b.x), minf(a.z, b.z))
			var box := Rect2(lo, Vector2(absf(a.x - b.x), absf(a.z - b.z)))
			out = {"anchor": spot, "box": box, "yaw": atan2(road.x, road.z)}
	_yards[lot] = out
	return out


## The first free spot in front of the house at c (road and side are unit tile steps), else NAN.
func _free_spot(c: Vector3, road: Vector3, side: Vector3) -> Vector3:
	var r := PACK.RADIUS_K * float(BODIES.BREEDS["husky"]["shoulder_m"]) * WS.M
	for depth: float in YARD_DEPTHS:
		for lat: float in YARD_SIDES:
			var p := c + road * depth + side * lat
			var y := ctx.collision.walk_height(p)
			if is_nan(y):
				continue
			p.y = y
			if not ctx.collision.is_blocked(p, r) and ctx.collision.surface_at(p) != "asphalt":
				return p
	return Vector3(NAN, NAN, NAN)


# ------------------------------------------------------------------ photo


## The house nearest the player with a front yard and sidewalk to stand on in front of it:
## {"lot", "yard", "at" (where its two dogs stand)}, or {}.
func _photo_yard() -> Dictionary:
	if ctx == null or ctx.sim == null or ctx.collision == null or ctx.directory == null:
		return {}
	var me := ctx.player_position()
	var best := {}
	var best_d := INF
	for i in range(ctx.sim.kind.size()):
		if ctx.sim.kind[i] != D.ZONE_R:
			continue
		var dist := _flat(_tile_pos(i), me)
		if dist >= best_d:
			continue
		var y := _yard(i)
		if y.is_empty():
			continue
		var pos := _photo_spot(i)
		if is_nan(pos.y) or ctx.collision.is_blocked(pos, WS.PLAYER_RADIUS):
			continue
		best = {"lot": i, "yard": y, "at": _photo_dogs(i, y)}
		best_d = dist
	return best


## Where the photo's dogs stand: the yard's spot moved toward the road to PHOTO_DEPTH (tiles from
## the middle of lot) when the ground there is free, else the spot itself.
func _photo_dogs(lot: int, y: Dictionary) -> Vector3:
	var a: Vector3 = y["anchor"]
	var c := _tile_pos(lot)
	var road := _tile_pos(ctx.directory.frontage(lot)) - c
	var p := a + road * maxf(PHOTO_DEPTH - (a - c).dot(road), 0.0)
	p.y = ctx.collision.walk_height(p)
	var r := PACK.RADIUS_K * float(BODIES.BREEDS["husky"]["shoulder_m"]) * WS.M
	if is_nan(p.y) or ctx.collision.is_blocked(p, r) or ctx.collision.surface_at(p) == "asphalt":
		return a
	return p


## Where the photo camera stands in front of lot (feet; y NAN off the ground).
func _photo_spot(lot: int) -> Vector3:
	var c := _tile_pos(lot)
	var pos := c + (_tile_pos(ctx.directory.frontage(lot)) - c) * PHOTO_BACK
	pos.y = ctx.collision.walk_height(pos)
	return pos


# ------------------------------------------------------------------ helpers


func _clear() -> void:
	if pack == null:
		return
	for d: PACK.Dog in pack.dogs.duplicate():
		_drop(d)
	if leads != null and is_instance_valid(leads):
		leads.draw([], Vector3.ZERO)


func _drop(d: PACK.Dog) -> void:
	bodies.release(d.body)
	pack.remove(d)


func _dog(id: int) -> PACK.Dog:
	for d: PACK.Dog in pack.dogs:
		if d.id == id:
			return d
	return null


func _dog_of(key: String) -> PACK.Dog:
	for d: PACK.Dog in pack.dogs:
		if d.key == key:
			return d
	return null


func _dog_of_walker(wid: int) -> PACK.Dog:
	for d: PACK.Dog in pack.dogs:
		if d.walker == wid:
			return d
	return null


## "Maria's husky", or "a husky" for someone passing through.
func _whose(d: PACK.Dog) -> String:
	var breed := str(BREED_NAMES.get(d.breed, d.breed))
	return ("a " + breed) if d.owner_name.is_empty() else "%s's %s" % [d.owner_name, breed]


## The middle of the dog's back (the pick target).
func _back(d: PACK.Dog) -> Vector3:
	return d.pos + Vector3(0.0, 0.75 * pack.shoulder_m(d) * WS.M, 0.0)


## True when a wall or the ground stands between origin and a dog t along dir.
func _hidden(origin: Vector3, dir: Vector3, t: float) -> bool:
	if ctx.collision == null:
		return false
	var hit := ctx.collision.raycast(origin, dir, t, false)
	return bool(hit["hit"]) and float(hit["dist"]) < t - OCCLUDE


func _driving() -> bool:
	var drive := ctx.feature("drive")
	return drive != null and bool(drive.get("active"))


func _night() -> float:
	return ctx.sky.night if ctx.sky != null else 0.0


func _raining() -> bool:
	var street := ctx.feature("streetscape")
	var w: Variant = street.get("weather") if street != null else null
	return w is Object and is_instance_valid(w) and str((w as Object).get("state")) == "rain"


## The share of people passing through who walk a dog now.
func _walk_share() -> float:
	var k := NIGHT_K if _night() > NIGHT else 1.0
	return WALK_SHARE * k * (RAIN_K if _raining() else 1.0)


## A number in [0, 1) that stays the same for key in this city.
func _roll(key: String) -> float:
	return float(absi(hash("%s:%d" % [key, ctx.sim.city_seed])) % 10000) / 10000.0


func _camera_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else ctx.player_position()


func _toast(t: String, kind: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(t, kind)


static func _tile_pos(i: int) -> Vector3:
	return Vector3(D.tx(i), 0.0, D.ty(i))


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Distance along the ray (o, unit d) to the ball (c, r), or -1 when it misses.
static func _ray_ball(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := c - o
	var t := oc.dot(d)
	var miss := oc.length_squared() - t * t
	if miss > r * r:
		return -1.0
	var half := sqrt(r * r - miss)
	return maxf(t - half, 0.0) if t + half >= 0.0 else -1.0
