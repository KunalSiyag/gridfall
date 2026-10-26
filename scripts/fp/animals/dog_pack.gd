extends RefCounted
## The dogs' behaviour; the animals feature decides who has a dog and feeds in the world before
## every step(). A dog on its lead walks at its owner's left, stops now and then to sniff until the
## lead pulls it on, and is let off the lead to roam around an owner who stands still (in a park,
## say); a yard dog keeps to the front of its home and barks at people going by when it is the
## barking kind. Around the hero a friendly dog looks up and wags, trots over to a crouching hero
## and hops when petted; a barky one barks, a shy one backs off. Swings, blows and shouts close by
## make dogs flinch and bark; a dog the hero strikes yelps, is knocked away and runs off (a barky
## one turns on the hero instead); a dog whose owner the hero hits defends them, growling, barking
## and going for the hero's legs (on_bite). A car about to run a dog down makes it leap aside. Every
## dog plays Walk or Gallop at the rate its speed asks for, and its DogRig wags the tail, turns the
## head to what it watches and jerks it up with each bark.

const WS := preload("res://scripts/fp/world_scale.gd")
const BODIES := preload("res://scripts/fp/animals/dog_bodies.gd")

## Heel: beside the owner's left foot (HEEL_SIDE m out past the dog's own radius) and HEEL_BACK m
## back, closing the gap at HEEL_GAIN (1/s).
const HEEL_SIDE := 0.3 * WS.M
const HEEL_BACK := 0.15 * WS.M
const HEEL_GAIN := 2.5
## The lead (m): a dog on its lead further from its owner's feet is pulled along.
const LEAD := 1.8 * WS.M
## An owner slower than STILL (m/s) for UNCLIP_S lets the dog off the lead; it roams within ROAM
## (m) of them, a yard dog within YARD of its spot.
const STILL := 0.15 * WS.M
const UNCLIP_S := 3.0
const ROAM := 6.0 * WS.M
const YARD := 2.4 * WS.M
## Speeds (m/s), acceleration (m/s²) and turn rate (rad/s).
const STROLL := 0.7 * WS.M
const TROT := 2.0 * WS.M
const RUN := 4.5 * WS.M
const ACCEL := 6.0 * WS.M
const TURN := 7.0
## Collision radius and height as shares of the height at the shoulder.
const RADIUS_K := 0.42
const HEIGHT_K := 1.3
## Clip rates: Walk from WALK_RATE.x to WALK_RATE.y times its own speed (a quick Walk stands in
## for the trot a small dog keeps up with its owner at), faster than that Gallop (back to Walk
## below WALK_BACK times the walk speed) at GALLOP_RATE.
const WALK_RATE := Vector2(0.45, 4.2)
const WALK_BACK := 3.6
const GALLOP_RATE := Vector2(0.6, 2.4)
## The hero: noticed within NOTICE (m), barked at by a barky dog within BARK_AT, avoided by a shy
## one within SHY, kept GAP clear of; a crouching hero within GREET draws a friendly dog over.
const NOTICE := 5.0 * WS.M
const BARK_AT := 3.0 * WS.M
const SHY := 1.4 * WS.M
const GAP := 0.25 * WS.M
const GREET := 4.0 * WS.M
const GREET_AT := 0.6 * WS.M
## Sprinting past closer than BRUSH (m) faster than BRUSH_MPS (m/s) startles a dog.
const BRUSH := 1.2 * WS.M
const BRUSH_MPS := 3.0 * WS.M
## Defending its owner: angry for ANGRY_S (s), it goes for the hero within LUNGE (m), the jaws
## closing BITE_AT s into its Attack clip (played at LUNGE_RATE) on a hero within BITE_REACH (m of
## the head); at most BITES bites, LUNGE_COOL s apart.
const ANGRY_S := 12.0
const LUNGE := 1.3 * WS.M
const LUNGE_RATE := 1.3
const BITE_AT := 0.4
const BITE_REACH := 0.8 * WS.M
const BITES := 2
const LUNGE_COOL := 2.0
## Struck by the hero (hit): knocked away at KNOCK (m/s) plus KNOCK_K times the blow's strength,
## flinching HIT_FLINCH s. A barky or angry dog struck softer than RUN_OFF then goes for the hero;
## any other runs off for HIT_FLEE s.
const KNOCK := 2.0 * WS.M
const KNOCK_K := 3.0 * WS.M
const HIT_FLINCH := 0.35
const RUN_OFF := 0.7
const HIT_FLEE := 3.0
## A volley's gap between barks (s) and the rest before a dog barks again on its own (s).
const BARK_GAP := Vector2(0.32, 0.6)
const BARK_REST := Vector2(10.0, 20.0)
## A car within its length plus DODGE_S seconds of travel ahead and DODGE_SIDE (m) beside its path
## makes a dog leap aside.
const DODGE_S := 1.2
const DODGE_SIDE := 0.6 * WS.M
## Where the hero's eyes are for a dog looking up at them (m), standing and crouched.
const EYES := Vector2(1.55 * WS.M, 0.95 * WS.M)
## People going by take this much room (m): a dog steps out of their way.
const PERSON_R := 0.25 * WS.M
const IDLES: Array[StringName] = [&"Idle", &"Idle_2", &"Idle_2_HeadLow"]
const ACT_CLIPS := {"hop": &"Jump_ToIdle", "lunge": &"Attack", "sniff": &"Eating"}
const NO_POINT := Vector3(NAN, NAN, NAN)


## One dog.
class Dog:
	extends RefCounted
	var id: int = 0
	## The feature's key for it: "r:<resident id>", "w:<walker id>" or "photo:<k>".
	var key: String = ""
	var name: String = ""
	var he: bool = true
	var breed: String = "shiba"
	var size: float = 1.0
	## "friendly", "barky" or "shy".
	var temper: String = "friendly"
	var body: BODIES.Body = null
	## The owner: their walker id (traffic's walkers_near, -1 for a yard dog), resident id and name
	## ("" for someone passing through).
	var walker: int = -1
	var owner_rid: String = ""
	var owner_name: String = ""
	## A resident's dog: the lot of their home (-1 otherwise); seconds its owner has been off the
	## street.
	var home: int = -1
	var lost: float = 0.0
	## A yard dog's lot, the spot it keeps to and the lot's xz rectangle (zero size otherwise).
	var lot: int = -1
	var anchor := Vector3.ZERO
	var lot_box := Rect2()
	## "heel" (on its lead or coming back to it), "roam" (off it) or "yard".
	var mode: String = "heel"
	var clipped: bool = true
	var pos := Vector3.ZERO
	## Facing (sin yaw, 0, cos yaw).
	var yaw: float = 0.0
	var speed: float = 0.0
	## A shove (u/s) from a flinch or a lunge, dying away.
	var push := Vector3.ZERO
	## What it is busy with: "", "sniff", "hop", "flinch", "lunge", "greet" or "flee".
	var act: String = ""
	var act_t: float = 0.0
	var act_age: float = 0.0
	var act_dir := Vector3.ZERO
	var flinch: StringName = &"Idle_HitReact_Left"
	## Where it runs off once the act under way ends (a struck dog, after the flinch); zero for
	## nowhere.
	var flee_after := Vector3.ZERO
	var restart: bool = false
	var goal := NO_POINT
	var goal_t: float = 0.0
	var trot: bool = false
	var sniff_t: float = 0.0
	var idle: StringName = &"Idle"
	var gallop: bool = false
	var barks: int = 0
	var bark_t: float = 0.0
	var bark_cool: float = 0.0
	var angry: float = 0.0
	var bites: int = 0
	var bit: bool = false
	var lunge_cool: float = 0.0
	var whine_cool: float = 0.0
	## 0..1: how hard the tail wags.
	var happy: float = 0.0
	var watch := NO_POINT
	var watch_t: float = 0.0
	var still_t: float = 0.0
	var owner_seen: bool = false
	var owner_pos := Vector3.ZERO
	var owner_vel := Vector3.ZERO
	var owner_yaw: float = 0.0
	var owner_down: bool = false
	var hand := Vector3.INF


var dogs: Array = []
var col: CollisionWorld = null
## Called with (dog, call) when a dog barks, growls or whines, and with (dog) when its lunge lands.
var on_call: Callable
var on_bite: Callable
## The world this step, set by the feature: the hero's feet and velocity, whether they are on foot
## (not driving, not in photo mode), open to a bite and crouched; moving cars as [pos, vel, half
## length, half width]; the feet of the people on foot around; the game's time scale.
var hero := Vector3(INF, INF, INF)
var hero_vel := Vector3.ZERO
var hero_on_foot: bool = false
var hero_open: bool = false
var crouched: bool = false
var cars: Array = []
var passers: Array = []
var time_scale: float = 1.0
var _rng := RandomNumberGenerator.new()
var _next_id: int = 1


func _init() -> void:
	_rng.seed = 8086


## A new dog with body b standing at pos facing yaw.
func add(b: BODIES.Body, pos: Vector3, yaw: float) -> Dog:
	var d := Dog.new()
	d.id = _next_id
	_next_id += 1
	d.body = b
	d.breed = b.breed
	d.pos = pos
	d.yaw = yaw
	d.idle = IDLES[_rng.randi() % IDLES.size()]
	d.sniff_t = _rng.randf_range(4.0, 14.0)
	d.bark_cool = _rng.randf_range(1.0, 4.0)
	dogs.append(d)
	return d


## Takes d off the street (the feature releases its body).
func remove(d: Dog) -> void:
	dogs.erase(d)


## Puts d on the lead of person wid (traffic's walkers_near id); follow() tells it where they are.
func to_owner(d: Dog, wid: int) -> void:
	d.walker = wid
	d.mode = "heel"
	d.clipped = false
	d.owner_seen = false
	d.lost = 0.0
	d.lot = -1
	d.lot_box = Rect2()
	d.goal = NO_POINT


## Sends d to keep to the front of lot: it roams within YARD of anchor, inside box (xz).
func to_yard(d: Dog, lot: int, anchor: Vector3, box: Rect2) -> void:
	d.walker = -1
	d.mode = "yard"
	d.clipped = false
	d.lot = lot
	d.anchor = anchor
	d.lot_box = box
	d.goal = NO_POINT
	d.goal_t = 0.0


## The owner this frame (traffic's walkers_by_id entry: feet, facing, down, hand); dt game s since
## the last one gives their velocity.
func follow(d: Dog, e: Dictionary, dt: float) -> void:
	var p: Vector3 = e["pos"]
	if d.owner_seen and dt > 0.0:
		var v := (p - d.owner_pos) / dt
		v.y = 0.0
		d.owner_vel = d.owner_vel.lerp(v.limit_length(RUN), 0.25)
	d.owner_seen = true
	d.owner_pos = p
	d.owner_yaw = float(e["yaw"])
	d.owner_down = bool(e["down"])
	d.hand = e.get("hand", Vector3.INF)


## One step of dt game seconds for every dog.
func step(dt: float) -> void:
	if dt <= 0.0:
		_freeze()
		return
	for d: Dog in dogs:
		_tick(d, dt)
		_sense(d, dt)
		_move(d, _want(d, dt), dt)
		_hold(d)
		_animate(d)
		_pose(d, dt)


## Starts a volley of n barks, unless the dog is barking or barked lately (force: anyway).
func bark(d: Dog, n: int, force: bool) -> void:
	if d.barks > 0 or (d.bark_cool > 0.0 and not force):
		return
	d.barks = n
	d.bark_t = 0.0
	d.bark_cool = _rng.randf_range(BARK_REST.x, BARK_REST.y)


## Something went off at src close by (a blow, a swing, a sprint past): the dog flinches away and
## barks; a shy one whines instead.
func startle(d: Dog, src: Vector3) -> void:
	if d.act == "lunge" or d.act == "flee":
		return
	var away := _away_from(d, src)
	_flinch_from(d, away, 0.6)
	d.push = away * TROT
	if d.temper == "shy":
		_whine(d)
	else:
		bark(d, 2, d.temper == "barky")


## The hero struck the dog (a kick or a weapon) from src at strength 0..1: it yelps and is knocked
## away, flinching. A barky dog, or one angry already, struck softer than RUN_OFF goes for the hero
## (defend); any other runs off whining once the flinch is over and is shy of the hero from then
## on. Returns true when it goes for the hero.
func hit(d: Dog, src: Vector3, strength: float) -> bool:
	var away := _away_from(d, src)
	_flinch_from(d, away, HIT_FLINCH)
	d.push = away * (KNOCK + KNOCK_K * strength)
	d.barks = 0
	d.happy = 0.0
	d.flee_after = Vector3.ZERO
	_call(d, "yelp")
	if strength < RUN_OFF and (d.temper == "barky" or d.angry > 0.0):
		defend(d)
		return true
	d.angry = 0.0
	d.temper = "shy"
	d.flee_after = away
	return false


## The dog's collision radius (u).
func girth(d: Dog) -> float:
	return _radius(d)


## The hero hit the dog's owner: it growls and barks, and goes for the hero while they are close.
func defend(d: Dog) -> void:
	d.angry = ANGRY_S
	d.bites = 0
	d.happy = 0.0
	if d.act in ["sniff", "greet", "hop"]:
		d.act = ""
	_call(d, "growl")
	d.barks = 0
	bark(d, 4, true)


## The hero pets the dog: it hops and wags, and a barky or shy dog warms to them. False, with a
## growl, while it is angry.
func pet(d: Dog) -> bool:
	if d.angry > 0.0:
		_call(d, "growl")
		return false
	_start(d, "hop", 1.2)
	d.happy = 1.0
	d.barks = 0
	d.temper = "friendly"
	return true


## The dog's head, and the ring on its collar the lead clips to (world points).
func head_of(d: Dog) -> Vector3:
	return BODIES.bone_point(d.body, d.body.head, Vector2(1.8, 2.65))


func collar_of(d: Dog) -> Vector3:
	return BODIES.bone_point(d.body, d.body.collar, Vector2(1.48, 2.16))


## Height at the shoulder (m).
func shoulder_m(d: Dog) -> float:
	return float(BODIES.BREEDS[d.breed]["shoulder_m"]) * d.size


## [hand, collar, lead length, ground y] of every lead on, for DogLeads.
func leads() -> Array:
	var out: Array = []
	for d: Dog in dogs:
		if d.walker >= 0 and d.mode == "heel" and d.clipped and d.hand.is_finite():
			out.append([d.hand, collar_of(d), LEAD * 0.9, d.pos.y])
	return out


# ------------------------------------------------------------------ per step


func _tick(d: Dog, dt: float) -> void:
	d.act_t -= dt
	d.act_age += dt
	if d.act == "lunge" and not d.bit and d.act_age >= BITE_AT / LUNGE_RATE:
		d.bit = true
		_bite(d)
	if d.act != "" and d.act_t <= 0.0:
		_act_over(d)
	for k: String in ["bark_cool", "lunge_cool", "whine_cool", "goal_t", "sniff_t", "watch_t"]:
		d.set(k, float(d.get(k)) - dt)
	var far := _flat(d.pos, hero) > NOTICE * 2.0
	d.angry = maxf(0.0, d.angry - dt * (3.0 if far else 1.0))
	d.happy = maxf(0.0, d.happy - 0.06 * dt)
	if d.barks > 0:
		d.bark_t -= dt
		if d.bark_t <= 0.0:
			d.barks -= 1
			d.bark_t = _rng.randf_range(BARK_GAP.x, BARK_GAP.y)
			if d.body.rig != null:
				d.body.rig.bark = 1.0
			_call(d, "bark")


func _bite(d: Dog) -> void:
	if not hero_open or _flat(head_of(d), hero) > BITE_REACH + WS.PLAYER_RADIUS:
		return
	d.bites += 1
	if d.bites >= BITES:
		d.angry = minf(d.angry, 2.0)
	if on_bite.is_valid():
		on_bite.call(d)


func _sense(d: Dog, dt: float) -> void:
	_owner_rules(d, dt)
	_dodge(d)
	if d.mode == "yard":
		_watch_passers(d)
	if d.act == "flee" or d.act == "lunge":
		return
	var dh := _flat(d.pos, hero) if hero_on_foot else INF
	if d.angry > 0.0:
		_go_for(d, dh)
		return
	var fast := Vector2(hero_vel.x, hero_vel.z).length() > BRUSH_MPS
	if dh < BRUSH and fast and d.act != "flinch":
		startle(d, hero)
		return
	match d.temper:
		"barky":
			if dh < BARK_AT and d.happy < 0.5:
				bark(d, _rng.randi_range(2, 4), false)
		"shy":
			if dh < SHY and d.act == "":
				_flee(d, d.pos - hero, 0.8)
		_:
			if crouched and dh < GREET and d.act == "" and _free(d):
				_start(d, "greet", 5.0)


## An owner who stands still lets the dog off the lead; one who walks on calls it back.
func _owner_rules(d: Dog, dt: float) -> void:
	if d.walker < 0:
		return
	var moving := Vector2(d.owner_vel.x, d.owner_vel.z).length() > STILL
	d.still_t = 0.0 if moving else d.still_t + dt
	if d.mode == "heel" and d.still_t > UNCLIP_S and not d.owner_down:
		d.mode = "roam"
		d.clipped = false
		d.goal = NO_POINT
	elif d.mode == "roam" and moving:
		d.mode = "heel"
		if d.act == "sniff" or d.act == "greet":
			d.act = ""


## True when the dog may leave its owner's side (off the lead, or the owner stands still).
func _free(d: Dog) -> bool:
	return d.mode != "heel" or d.still_t > 0.5


func _go_for(d: Dog, dh: float) -> void:
	if dh < LUNGE and hero_open and d.lunge_cool <= 0.0 and d.bites < BITES:
		var secs := _clip_len(d, &"Attack", 1.2) / LUNGE_RATE
		_start(d, "lunge", secs)
		d.bit = false
		d.lunge_cool = LUNGE_COOL + secs
		var to := hero - d.pos
		to.y = 0.0
		d.push = to.normalized() * TROT if to.length_squared() > 1e-12 else Vector3.ZERO
		_call(d, "growl")
	elif d.barks == 0 and dh < NOTICE * 2.0:
		bark(d, 3, false)


## People going by a yard dog: it watches them, and a barky one runs to the edge of the lot and
## barks.
func _watch_passers(d: Dog) -> void:
	for p: Vector3 in passers:
		if _flat(p, d.pos) > NOTICE:
			continue
		d.watch = p + Vector3(0.0, EYES.x, 0.0)
		d.watch_t = 1.5
		if d.temper == "barky" and d.bark_cool <= 0.0 and d.angry <= 0.0:
			bark(d, _rng.randi_range(3, 5), false)
			d.goal = _bounded(d, p)
			d.goal_t = 3.0
			d.trot = true
		return


func _dodge(d: Dog) -> void:
	for c: Array in cars:
		var side := car_danger(d.pos, c, DODGE_SIDE)
		if side == Vector3.ZERO:
			continue
		if d.act != "flee":
			_flee(d, side, 0.9)
			_whine(d)
		_clear_of(d, c, side)
		return


## The way to leap from car c ([pos, vel, half length, half width]) when it is about to run down
## an animal at p (within its length plus DODGE_S of travel ahead and side_m beside its path),
## else ZERO.
static func car_danger(p: Vector3, c: Array, side_m: float) -> Vector3:
	var vel: Vector3 = c[1]
	var sp := Vector2(vel.x, vel.z).length()
	var rel: Vector3 = p - (c[0] as Vector3)
	if sp < 1.0 * WS.M or absf(rel.x) + absf(rel.z) > 1.0:
		return Vector3.ZERO
	var dir := Vector3(vel.x, 0.0, vel.z) / sp
	var along := rel.x * dir.x + rel.z * dir.z
	var lat := rel.z * dir.x - rel.x * dir.z
	var hl := float(c[2])
	if along < -hl or along > hl + sp * DODGE_S or absf(lat) > float(c[3]) + side_m:
		return Vector3.ZERO
	return Vector3(-dir.z, 0.0, dir.x) * (1.0 if lat >= 0.0 else -1.0)


## A dog already under car c's body is shoved out of it along side.
func _clear_of(d: Dog, c: Array, side: Vector3) -> void:
	var rel: Vector3 = d.pos - (c[0] as Vector3)
	var vel: Vector3 = c[1]
	var dir := Vector3(vel.x, 0.0, vel.z).normalized()
	var along := absf(rel.x * dir.x + rel.z * dir.z)
	var lat := absf(rel.x * side.x + rel.z * side.z)
	var out := float(c[3]) + _radius(d) - lat
	if along < float(c[2]) and out > 0.0:
		_slide(d, side * out)


func _want(d: Dog, dt: float) -> Vector3:
	if d.act == "flee":
		return d.act_dir * RUN
	if d.act == "greet":
		return _greet(d)
	if d.act != "":
		return Vector3.ZERO
	if d.angry > 0.0 and hero_on_foot:
		return _arrive(d, _bounded(d, _beside_hero(d, 0.7 * WS.M)), RUN)
	return _heel(d, dt) if d.mode == "heel" else _roam(d)


func _heel(d: Dog, dt: float) -> Vector3:
	var fwd := Vector3(sin(d.owner_yaw), 0.0, cos(d.owner_yaw))
	var left := Vector3(fwd.z, 0.0, -fwd.x)
	var spot := d.owner_pos + left * (HEEL_SIDE + _radius(d)) - fwd * HEEL_BACK
	var err := spot - d.pos
	err.y = 0.0
	if d.still_t > 0.0:
		if err.length() < 0.5 * WS.M:
			_maybe_sniff(d)
			return Vector3.ZERO
		return _arrive(d, spot, TROT)
	if d.sniff_t <= 0.0 and _rng.randf() < dt * 0.2:
		_start(d, "sniff", _rng.randf_range(1.2, 2.4))
		d.sniff_t = _rng.randf_range(12.0, 25.0)
		return Vector3.ZERO
	return (d.owner_vel + err * HEEL_GAIN).limit_length(RUN)


## Wanders between spots around its owner (roam) or its yard, stopping to sniff and look about.
func _roam(d: Dog) -> Vector3:
	if not is_nan(d.goal.x) and _flat(d.pos, d.goal) < 0.25 * WS.M:
		d.goal = NO_POINT
		d.goal_t = _rng.randf_range(1.5, 5.0)
		_maybe_sniff(d)
		return Vector3.ZERO
	if not is_nan(d.goal.x) and d.goal_t <= 0.0:
		d.goal = NO_POINT
		d.goal_t = 1.0
	if is_nan(d.goal.x):
		if d.goal_t > 0.0:
			return Vector3.ZERO
		var yard := d.mode == "yard"
		d.goal = _pick_goal(d, d.anchor if yard else d.owner_pos, YARD if yard else ROAM)
		d.goal_t = _rng.randf_range(5.0, 10.0)
		d.trot = _rng.randf() < 0.25
		if is_nan(d.goal.x):
			return Vector3.ZERO
	return _arrive(d, d.goal, TROT if d.trot else STROLL)


func _pick_goal(d: Dog, center: Vector3, radius: float) -> Vector3:
	for _k in range(6):
		var a := _rng.randf() * TAU
		var p := center + Vector3(cos(a), 0.0, sin(a)) * radius * sqrt(_rng.randf())
		if d.lot_box.has_area() and not d.lot_box.has_point(Vector2(p.x, p.z)):
			continue
		if col == null:
			return p
		var y := col.walk_height(p)
		p.y = y
		if not is_nan(y) and not col.is_blocked(p, _radius(d)) and col.surface_at(p) != "asphalt":
			return p
	return NO_POINT


func _greet(d: Dog) -> Vector3:
	if not hero_on_foot or _flat(d.pos, hero) > GREET * 1.3:
		d.act = ""
		return Vector3.ZERO
	d.happy = maxf(d.happy, 0.6)
	return _arrive(d, _bounded(d, _beside_hero(d, GREET_AT)), TROT)


## The point dist from the hero on the dog's side of them.
func _beside_hero(d: Dog, dist: float) -> Vector3:
	var to := d.pos - hero
	to.y = 0.0
	var dir := to.normalized() if to.length_squared() > 1e-12 else Vector3.BACK
	return hero + dir * dist


## p kept inside the dog's lot, or within its lead (or roam) of its owner.
func _bounded(d: Dog, p: Vector3) -> Vector3:
	if d.lot_box.has_area():
		var q := Vector2(p.x, p.z).clamp(d.lot_box.position, d.lot_box.end)
		return Vector3(q.x, p.y, q.y)
	if d.walker < 0:
		return p
	var lim := LEAD if d.mode == "heel" else ROAM
	var off := p - d.owner_pos
	off.y = 0.0
	return d.owner_pos + off.limit_length(lim)


func _arrive(d: Dog, target: Vector3, vmax: float) -> Vector3:
	var to := target - d.pos
	to.y = 0.0
	var dist := to.length()
	if dist < 0.12 * WS.M:
		return Vector3.ZERO
	return to / dist * minf(vmax, dist * 2.5)


## Turns toward want (or the hero it faces off) and runs at want's speed as far as it faces it.
func _move(d: Dog, want: Vector3, dt: float) -> void:
	var wl := Vector2(want.x, want.z).length()
	var face := d.yaw
	if wl > 0.05 * WS.M:
		face = atan2(want.x, want.z)
	elif _faces_hero(d):
		face = atan2(hero.x - d.pos.x, hero.z - d.pos.z)
	d.yaw = rotate_toward(d.yaw, face, TURN * dt)
	var align := maxf(0.0, cos(angle_difference(d.yaw, face)))
	d.speed = move_toward(d.speed, wl * align, ACCEL * dt)
	var fwd := Vector3(sin(d.yaw), 0.0, cos(d.yaw))
	_slide(d, fwd * d.speed * dt + d.push * dt)
	d.push = d.push.move_toward(Vector3.ZERO, ACCEL * 2.0 * dt)


func _faces_hero(d: Dog) -> bool:
	if not hero_on_foot or _flat(d.pos, hero) > NOTICE:
		return false
	return d.angry > 0.0 or d.barks > 0 or d.act == "lunge" or d.act == "hop"


## The lead pulls a dog that strayed past it (a sniff ends), and nobody walks through the hero.
func _hold(d: Dog) -> void:
	if d.walker >= 0 and d.mode == "heel":
		var off := d.pos - d.owner_pos
		off.y = 0.0
		var far := off.length()
		if not d.clipped and far <= LEAD:
			d.clipped = true
		if d.clipped and far > LEAD:
			if d.act == "sniff":
				d.act = ""
			var to := d.owner_pos + off / far * LEAD
			_slide(d, to - d.pos)
			if _flat(d.pos, d.owner_pos) > LEAD * 1.5:
				_snap(d, to)
	if hero_on_foot:
		_keep_off(d, hero, GAP + _radius(d) + WS.PLAYER_RADIUS)
	for p: Vector3 in passers:
		if d.walker < 0 or _flat(p, d.owner_pos) > 0.05 * WS.M:
			_keep_off(d, p, PERSON_R + _radius(d))
	for o: Dog in dogs:
		if o != d:
			_keep_off(d, o.pos, _radius(o) + _radius(d))


## Slides d out of the circle of radius r around p (xz).
func _keep_off(d: Dog, p: Vector3, r: float) -> void:
	var away := d.pos - p
	away.y = 0.0
	if absf(away.x) > r or absf(away.z) > r:
		return
	var dist := away.length()
	if dist < r and dist > 1e-6:
		_slide(d, away / dist * (r - dist))


func _slide(d: Dog, motion: Vector3) -> void:
	motion.y = 0.0
	if motion.length_squared() < 1e-14:
		return
	var np := d.pos + motion
	if col != null:
		np = col.move_body(
			d.pos, motion, _radius(d), HEIGHT_K * shoulder_m(d) * WS.M, WS.STEP_HEIGHT
		)
		var y := col.walk_height(np)
		if is_nan(y):
			d.speed = 0.0
			return
		np.y = y
	d.pos = np


func _snap(d: Dog, p: Vector3) -> void:
	var y := col.walk_height(p) if col != null else p.y
	if not is_nan(y):
		d.pos = Vector3(p.x, y, p.z)


func _animate(d: Dog) -> void:
	var b := d.body
	b.root.position = d.pos
	b.root.rotation = Vector3(0.0, d.yaw, 0.0)
	var clip: StringName = ACT_CLIPS.get(d.act, &"")
	var rate := LUNGE_RATE if d.act == "lunge" else 1.0
	if d.act == "flinch":
		clip = d.flinch
	if clip == &"":
		var walk := BODIES.gait_speed(b, false)
		d.gallop = d.speed > walk * (WALK_BACK if d.gallop else WALK_RATE.y)
		if d.speed < 0.04 * WS.M:
			clip = d.idle
		elif d.gallop:
			clip = &"Gallop"
			rate = clampf(d.speed / BODIES.gait_speed(b, true), GALLOP_RATE.x, GALLOP_RATE.y)
		else:
			clip = &"Walk"
			rate = clampf(d.speed / walk, WALK_RATE.x, WALK_RATE.y)
	BODIES.play(b, clip, rate * time_scale, d.restart)
	d.restart = false


## The tail and the head: a still tail on an angry or barking dog, a wag by its mood otherwise;
## eyes on the hero close by, on what it watches, or up at its owner standing beside it.
func _pose(d: Dog, dt: float) -> void:
	var rig := d.body.rig
	if rig == null:
		return
	rig.pace = time_scale
	var wag := maxf(d.happy, 0.3 if d.speed > STILL else 0.15)
	if d.angry > 0.0 or d.barks > 0:
		wag = 0.0
	rig.wag = lerpf(rig.wag, wag, 1.0 - exp(-3.0 * dt))
	rig.look = NO_POINT
	if hero_on_foot and _flat(d.pos, hero) < NOTICE:
		rig.look = hero + Vector3(0.0, EYES.y if crouched else EYES.x, 0.0)
	elif d.watch_t > 0.0:
		rig.look = d.watch
	elif d.walker >= 0 and d.still_t > 0.5 and _flat(d.pos, d.owner_pos) < 1.5 * WS.M:
		rig.look = d.owner_pos + Vector3(0.0, EYES.x, 0.0)


# ------------------------------------------------------------------ helpers


## The game is paused: every clip and every tail stops where it is.
func _freeze() -> void:
	for d: Dog in dogs:
		if d.body.ap != null:
			d.body.ap.speed_scale = 0.0
		if d.body.rig != null:
			d.body.rig.pace = 0.0


func _start(d: Dog, act: String, secs: float) -> void:
	d.act = act
	d.act_t = secs
	d.act_age = 0.0
	d.restart = true


## The act ran its time: the dog stands, or runs off whining when it was struck.
func _act_over(d: Dog) -> void:
	d.act = ""
	if d.flee_after != Vector3.ZERO:
		_flee(d, d.flee_after, HIT_FLEE)
		d.flee_after = Vector3.ZERO
		_whine(d)


## The way from src to the dog (flat, unit), or behind it when they coincide.
func _away_from(d: Dog, src: Vector3) -> Vector3:
	var away := d.pos - src
	away.y = 0.0
	if away.length_squared() < 1e-12:
		away = -Vector3(sin(d.yaw), 0.0, cos(d.yaw))
	return away.normalized()


## Flinches away (the hit reaction to that side) for secs.
func _flinch_from(d: Dog, away: Vector3, secs: float) -> void:
	var right := Vector3(-cos(d.yaw), 0.0, sin(d.yaw))
	d.flinch = &"Idle_HitReact_Left" if away.dot(right) > 0.0 else &"Idle_HitReact_Right"
	_start(d, "flinch", secs)


func _flee(d: Dog, dir: Vector3, secs: float) -> void:
	dir.y = 0.0
	if dir.length_squared() < 1e-12:
		return
	_start(d, "flee", secs)
	d.act_dir = dir.normalized()
	d.flee_after = Vector3.ZERO


func _maybe_sniff(d: Dog) -> void:
	if d.sniff_t > 0.0:
		return
	_start(d, "sniff", _rng.randf_range(2.0, 4.0))
	d.sniff_t = _rng.randf_range(6.0, 14.0)
	d.idle = IDLES[_rng.randi() % IDLES.size()]


func _whine(d: Dog) -> void:
	if d.whine_cool <= 0.0:
		d.whine_cool = 4.0
		_call(d, "whine")


func _call(d: Dog, sound: String) -> void:
	if on_call.is_valid():
		on_call.call(d, sound)


func _radius(d: Dog) -> float:
	return RADIUS_K * shoulder_m(d) * WS.M


static func _clip_len(d: Dog, clip: StringName, fallback: float) -> float:
	var ap := d.body.ap
	if ap == null or not ap.has_animation(clip):
		return fallback
	return ap.get_animation(clip).length


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
