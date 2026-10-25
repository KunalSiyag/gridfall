extends RefCounted
## People hit in the street (docs/fp/ARCHITECTURE.md, Body actions): shoved or punched by the
## player, struck by the car they drive or dragged out of their own (carjack). A light blow makes
## the person reel (hit_chest, hit_head) and slide back a little; a hard one (DOWN), the
## HITS_DOWN-th punch in a row or a fast car knocks them down (knockback), and they lie a while
## before they get up (get_up). Then they shake their head or shout at whoever did it, run off, or
## walk back to where they were; some of those shoved or punched fight back instead (fight_back):
## they square up to the hero, close in and throw jabs and crosses (on_hero_hit) until the hero is
## down, gets away or drives off. People within WITNESS_R who see it run off or shout too. While a
## walker stands where the blow left it its state is "react" (it keeps its edge and plan; the
## slide and the walk back move only its drawn offset), and a run gives it its own state back at
## RUN_F times its pace with the run clip. The hero may take hold of someone (grab): they hang in
## the hero's hands (hold_to) in HOLD_CLIP, reeling from blows without falling free, until let go
## (release), knocked down or HOLD_S is up, then react as to a shove. A punch thrown at the hero
## is announced as it starts (on_wind_up) and may be countered as it arrives (on_hero_parry). What
## follows a blow for the city (memory, mood, crews) is incidents.gd's.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
## Clip lengths (s) in HC's libraries (the female clips match); setup() reads them again.
const LENGTHS := {&"knockback": 0.833, &"get_up": 1.54, &"hit_head": 0.417, &"hit_chest": 0.333}
## Clips that play once: the walker does not turn while they run (it may be lying down).
const ONCE: Array[StringName] = [&"knockback", &"get_up", &"hit_head", &"hit_chest"]
const WITNESS_R := 8.0 * WS.M
## A blow this strong (0..1) knocks a person down, and so does the HITS_DOWN-th punch within
## HITS_S seconds.
const DOWN := 0.7
const HITS_DOWN := 3
const HITS_S := 8.0
const RUN_F := 2.6
const BACK_V := 1.1 * WS.M
const BODY_R := 0.25 * WS.M
const BODY_H := 1.7 * WS.M
## Share of the people around who react, and of those the share who run off, by severity (a
## shove, a punch, a knock-down).
const SEE: Array[float] = [0.3, 0.6, 0.85]
const FLEE: Array[float] = [0.15, 0.5, 0.6]
## Who answers an emote of the hero's: [range (m), the cosine of the cone ahead, share, clip,
## seconds]. A share of 0 is the nearest person in the cone; otherwise each of those around
## answers with that chance, at most ANSWER_MAX of them.
const ANSWERS := {
	"wave": [10.0, 0.75, 0.0, &"wave", 2.8],
	"yes": [5.0, 0.75, 0.0, &"yes", 2.5],
	"no": [5.0, 0.75, 0.0, &"no", 2.0],
	"shout": [10.0, -1.0, 0.5, &"no", 2.0],
	"dance": [8.0, -1.0, 0.4, &"wave", 2.8],
}
const ANSWER_MAX := 4
## Fighting back (fight_back): the share of those shoved or punched (and not knocked down) who do,
## by cause (fight_odds starts as this); how long a fight may last (s); how close they come (feet
## to feet; within FIGHT_SLACK of it counts), from how far they run there and beyond how far they
## give up.
const FIGHT_ODDS := {"shove": 0.3, "punch": 0.4}
const FIGHT_S := 20.0
const FIGHT_REACH := 0.9 * WS.M
const FIGHT_SLACK := 0.05 * WS.M
const FIGHT_RUN := 3.0 * WS.M
const FIGHT_LOST := 12.0 * WS.M
## Their punches in turn: [clip, contact time (s), strength 0..1, seconds the clip plays]; the
## pause between two (s) and before the first.
const FIGHT_BLOWS := [[&"punch_jab", 0.2, 0.45, 0.7], [&"punch_cross", 0.29, 0.6, 0.8]]
const FIGHT_GAP := Vector2(0.45, 1.1)
const FIGHT_FIRST := 0.25
## A punch lands on the hero within FIGHT_HIT (feet to feet) inside the cone ahead (the cosine),
## from the fist FIST ahead and up (metres), and pushes them on at FIGHT_PUSH (u/s).
const FIGHT_HIT := 1.25 * WS.M
const FIGHT_CONE := 0.5
const FIST := Vector2(0.5, 1.45)
const FIGHT_PUSH := 1.5 * WS.M
## A knock-down throws the body (hit_feel flag): up LIFT (metres, by strength: a blow, a car) over
## FLY_S seconds, back to the ground, then up BOUNCE of that again over BOUNCE_S.
const LIFT := {"blow": Vector2(0.12, 0.3), "car": Vector2(0.3, 0.9)}
const FLY_S := 0.32
const BOUNCE := 0.2
const BOUNCE_S := 0.18
## Held by the hero: HOLD_CLIP stopped HOLD_AT seconds in (recoiling); they break free after
## HOLD_S. A throw (hit's fling) slides the body over FLING_S.
const HOLD_CLIP := &"hit_chest"
const HOLD_AT := 0.12
const HOLD_S := 6.0
const FLING_S := 0.7
## With hit_feel a throw flies the body up THROW_LIFT times the fling (metres) on a ballistic arc
## (gravity G, m/s²), tipped back by up to THROW_TILT (rad) at its height, across all but
## THROW_SKID metres of the fling, which it skids along the ground over SKID_S.
const THROW_LIFT := 0.3
const G := 9.8
const THROW_TILT := 0.7
const THROW_SKID := 0.5
const SKID_S := 0.35
## Dragged out of a car (drag_out): from the seat to beside the door over DRAG_S, in DRAG_CLIP held
## at DRAG_AT, lifted DRAG_LIFT over the sill and tipped back up to DRAG_TILT (rad).
const DRAG_S := 0.5
const DRAG_CLIP := &"sit"
const DRAG_AT := 1.0
const DRAG_LIFT := 0.2 * WS.M
const DRAG_TILT := 0.5


## One person reacting: the steps still to come, [mode, clip, seconds] with mode "place" (stand
## and play the clip), "back" (walk back to the walker's own place), "run", "fight" or "held" (in
## the hero's hands).
class Reaction:
	extends RefCounted
	var w: WK.Walker = null
	var steps: Array = []
	var mode: String = ""
	var left: float = 0.0  # seconds left in the current step
	var delay: float = 0.0  # someone who saw it takes a moment
	var src := Vector3.ZERO  # who did it: faced, run from
	var slide := Vector3.ZERO  # drawn offset the blow adds, eased out over slide_s
	var slide_t: float = 0.0
	var slide_s: float = 0.0
	var lift: float = 0.0  # how high a knock-down throws the body (u); 0 for none
	var fly_t: float = 0.0  # seconds since the blow, for the throw
	var bump: float = 0.0  # the throw's height in the drawn feet now (u)
	var fly_s: float = FLY_S  # seconds the body is in the air
	var tilt: float = 0.0  # how far a throw tips the body back at its height (rad)
	var air: float = 0.0  # a throw's seconds in the air, its slide steady; 0 for an eased slide
	var skid: float = 0.0  # the share of a throw's slide skidded along the ground
	var drag: Array = []  # dragged out of a car: [from, to, yaw from, yaw to]
	var was: String = ""  # walker state to give back ("" until the first step starts)
	var speed: float = 0.0  # pace to give back after a run
	var victim: bool = false
	var down: bool = false
	var hits: int = 0
	var last: float = -INF
	var fighter: bool = false  # fights the hero back (fight_back)
	var blow: int = 0  # FIGHT_BLOWS index of the next punch
	var blow_t: float = -1.0  # seconds into the punch under way; < 0 when none is
	var pause: float = 0.0  # seconds before the next punch may start
	var held: bool = false  # the hero holds them (grab), reeling from a blow included
	var hold_left: float = 0.0  # seconds before they break free
	var hold_p := Vector3.ZERO  # where the hero's hands put their feet
	var hold_yaw: float = 0.0


var wk: WK
var collision: CollisionWorld
var lengths: Dictionary = LENGTHS.duplicate()
var clock: float = 0.0
var _active: Dictionary = {}  # walker id -> Reaction
var _rng := RandomNumberGenerator.new()
## The hero can be fought now (on foot and in control; traffic sets it every step), and who hears
## of a punch that lands on them: on_hero_hit(at, strength, push).
var hero_open: bool = false
var on_hero_hit: Callable
## Who hears of a punch thrown at the hero as it starts: on_wind_up(walker id, fist, seconds until
## it lands); and who may counter it as it lands: on_hero_parry(walker id, fist) -> true when it
## is countered (it then misses).
var on_wind_up: Callable
var on_hero_parry: Callable
## The share who fight back, by cause (test hook), and the punches that landed on the hero or
## were countered.
var fight_odds: Dictionary = FIGHT_ODDS.duplicate()
var punches_landed: int = 0
var punches_parried: int = 0


func setup(p_wk: WK, p_collision: CollisionWorld, seed: int) -> void:
	wk = p_wk
	collision = p_collision
	_rng.seed = seed * 9157 + 5
	_active.clear()
	clock = 0.0
	if not ResourceLoader.exists(AP.CHAR_LIB_M):
		return
	var lib := load(AP.CHAR_LIB_M) as AnimationLibrary
	for n: StringName in LENGTHS.keys():
		if lib != null and lib.has_animation(n):
			lengths[n] = lib.get_animation(n).length


func clear() -> void:
	_active.clear()


## w takes a blow from src (a world point) along push (xz, any length) of strength 0..1, cause
## "shove", "punch", "car" or "carjack"; fling (m) > 0 throws a body it knocks down that far. Held
## (grab) and not knocked down, w reels and hangs on. Returns {"down": bool, "clip": StringName},
## or {} when w cannot take one now (hidden, in a conversation, or down already).
func hit(
	w: WK.Walker, src: Vector3, push: Vector3, strength: float, cause: String, fling: float = 0.0
) -> Dictionary:
	var r := _take(w)
	if r == null:
		return {}
	r.victim = true
	r.delay = 0.0
	r.hits = r.hits + 1 if clock - r.last < HITS_S else 1
	r.last = clock
	r.src = src
	var d := _away(w, src, push)
	r.down = strength >= DOWN or (cause == "punch" and r.hits >= HITS_DOWN)
	# Facing the blow; a box in the hands is dropped.
	w.yaw = atan2(-d.x, -d.z)
	w.extra = 0 if w.extra == 1 else w.extra
	var clip: StringName
	if r.down:
		clip = _plan_down(r, d, strength, cause, fling)
	else:
		clip = _plan_reel(r, d, strength, cause)
	if r.held:
		_keep_held(r)
	r.steps.append_array(_after(r, cause))
	r.slide_t = 0.0
	r.fly_t = 0.0
	_next_step(r)
	return {"down": r.down, "clip": clip}


## w's reaction, made for it when it has none; null when it cannot react now (dead, hidden, in a
## conversation or down). A run is called off.
func _take(w: WK.Walker) -> Reaction:
	if w.dead or w.state == "hidden" or w.hold:
		return null
	var r: Reaction = _active.get(w.id)
	if r != null and r.down:
		return null
	if r == null:
		return _new(w)
	if r.mode == "run":
		w.speed = r.speed
		w.react = &""
	return r


## A blow on someone held: knocked down they fall free, else they hang on in the hands (no slide)
## once the reel is over.
func _keep_held(r: Reaction) -> void:
	if r.down:
		r.held = false
		return
	r.slide = Vector3.ZERO
	r.steps.append(["held", HOLD_CLIP, r.hold_left])


## The hero takes hold of w (src: the hero's feet): it hangs in the hero's hands, where hold_to
## puts it, until let go (release), knocked down or HOLD_S is up, then reacts as to a shove. False
## when w cannot be held now (as hit()).
func grab(w: WK.Walker, src: Vector3) -> bool:
	var r := _take(w)
	if r == null:
		return false
	r.victim = true
	r.delay = 0.0
	r.src = src
	r.held = true
	r.hold_left = HOLD_S
	r.hold_p = w.pos + w.vis_off
	r.hold_yaw = w.yaw
	r.blow_t = -1.0
	r.slide_t = r.slide_s
	w.extra = 0 if w.extra == 1 else w.extra
	r.steps = [["held", HOLD_CLIP, HOLD_S]]
	r.steps.append_array(_after(r, "shove"))
	_next_step(r)
	return true


## Where the hero's hands hold w now: its feet go to p (stopped by walls and posts), turned to
## yaw. False once w is no longer held.
func hold_to(w: WK.Walker, p: Vector3, yaw: float) -> bool:
	var r: Reaction = _active.get(w.id)
	if r == null or not r.held:
		return false
	r.hold_p = p
	r.hold_yaw = yaw
	return true


## The hero lets go of w: it reacts as to a shove from where it stands.
func release(w: WK.Walker) -> void:
	var r: Reaction = _active.get(w.id)
	if r == null or not r.held:
		return
	r.held = false
	r.steps = r.steps.filter(func(s: Array) -> bool: return str(s[0]) != "held")
	if r.mode == "held":
		_next_step(r)


## True while the hero holds w.
func held(w: WK.Walker) -> bool:
	var r: Reaction = _active.get(w.id)
	return r != null and r.held


## Unit xz direction the blow pushes w: push, else away from src, else backward.
static func _away(w: WK.Walker, src: Vector3, push: Vector3) -> Vector3:
	var d := Vector3(push.x, 0.0, push.z)
	if d.length_squared() < 1e-12:
		d = Vector3(w.pos.x - src.x, 0.0, w.pos.z - src.z)
	if d.length_squared() < 1e-12:
		d = -Vector3(sin(w.yaw), 0.0, cos(w.yaw))
	return d.normalized()


## Knocked down: the fall and its slide (further for a car, fling metres for a throw), a while on
## the ground, getting up.
func _plan_down(
	r: Reaction, d: Vector3, strength: float, cause: String, fling: float = 0.0
) -> StringName:
	var car := cause == "car"
	var lie := lerpf(2.5, 6.0, strength) if car else _rng.randf_range(1.2, 2.4)
	var m := lerpf(1.5, 4.0, strength) if car else lerpf(0.8, 1.4, strength)
	r.steps = [
		["place", &"knockback", float(lengths[&"knockback"]) + lie],
		["place", &"get_up", float(lengths[&"get_up"])],
	]
	r.slide = d * ((fling if fling > 0.0 else m) * WS.M)
	r.slide_s = FLING_S if fling > 0.0 else 0.55
	var lift: Vector2 = LIFT["car" if car else "blow"]
	r.lift = lerpf(lift.x, lift.y, clampf(strength, 0.0, 1.0)) * WS.M
	r.fly_s = FLY_S
	r.air = 0.0
	r.tilt = 0.0
	if not FeatureFlags.enabled("hit_feel"):
		r.lift = 0.0
	elif fling > 0.0:
		# Thrown: up on a real arc, tipped back, and down onto the ground to skid the rest.
		var h := fling * THROW_LIFT
		r.lift = h * WS.M
		r.fly_s = 2.0 * sqrt(2.0 * h / G)
		r.air = r.fly_s
		r.skid = clampf(THROW_SKID / fling, 0.0, 0.5)
		r.slide_s = r.air + SKID_S
		r.tilt = THROW_TILT
	return &"knockback"


## A light blow: reeling back (head for a punch, chest otherwise; the other one when the same clip
## is playing, so a second blow shows).
func _plan_reel(r: Reaction, d: Vector3, strength: float, cause: String) -> StringName:
	var clip: StringName = &"hit_head" if cause == "punch" else &"hit_chest"
	if r.w.react == clip:
		clip = &"hit_chest" if clip == &"hit_head" else &"hit_head"
	var ln := float(lengths[clip])
	r.steps = [["place", clip, ln]]
	r.lift = 0.0
	r.slide = d * (lerpf(0.25, 0.6, strength) * WS.M)
	r.slide_s = ln * 0.8
	return clip


## What a victim does once the blow is over: shakes their head at a shove or shouts at a punch, a
## car or a carjack; after a punch or a carjack they run off when they can, else they walk back to
## their place. One who fights back shouts, goes for the hero, then walks back (straight back at
## it when hit mid-fight).
func _after(r: Reaction, cause: String) -> Array:
	var shout := ["place", &"no" if cause == "shove" else &"shout", _rng.randf_range(1.6, 2.6)]
	if not r.down and _fights_back(r, cause):
		var fight := ["fight", &"", FIGHT_S]
		if r.mode == "fight":
			return [fight, ["back", &"", 30.0]]
		return [["place", &"shout", 0.8], fight, ["back", &"", 30.0]]
	if (cause == "punch" or cause == "carjack") and _can_run(r):
		return [shout, _run_step()]
	return [shout, ["back", &"", 30.0]]


func _run_step() -> Array:
	return ["run", &"run", _rng.randf_range(4.0, 7.0)]


## True when r's walker fights the hero back: always once they have, else by fight_odds for the
## cause while the hero can be fought.
func _fights_back(r: Reaction, cause: String) -> bool:
	if not r.fighter and hero_open and FeatureFlags.enabled("fight_back"):
		r.fighter = _rng.randf() < float(fight_odds.get(cause, 0.0))
	return r.fighter


## True when r's walker can run off: it was walking somewhere (an edge or a free leg).
func _can_run(r: Reaction) -> bool:
	var st := r.was if not r.was.is_empty() else r.w.state
	return (st == "walk" or st == "chat") and (r.w.edge != null or r.w.on_leg)


## People within WITNESS_R of w who see what happened to it (severity 0 a shove, 1 a punch, 2 a
## knock-down) and are not reacting already: some run off, some shout at src (shake their head at
## a shove). Returns them.
func witness(w: WK.Walker, src: Vector3, severity: int) -> Array:
	var out: Array = []
	var s := clampi(severity, 0, 2)
	var r2 := WITNESS_R * WITNESS_R
	for o: WK.Walker in wk.walkers:
		if o == w or not _free(o):
			continue
		if o.pos.distance_squared_to(w.pos) > r2 or _rng.randf() > SEE[s]:
			continue
		var r := _new(o)
		r.src = src
		r.delay = _rng.randf_range(0.2, 0.7)
		if _can_run(r) and _rng.randf() < FLEE[s]:
			r.steps = [_run_step()]
		else:
			r.steps = [["place", &"no" if s == 0 else &"shout", _rng.randf_range(1.5, 3.0)]]
		out.append(o)
	return out


## People who answer the hero's emote ("wave", "yes", "no", "shout", "dance"; ANSWERS) made at
## p facing fwd (xz): after a moment they turn to p and wave, nod or shake their head. Returns
## them.
func answer_emote(p: Vector3, fwd: Vector3, emote: String) -> Array:
	var spec: Array = ANSWERS.get(emote, [])
	var out: Array = []
	if spec.is_empty():
		return out
	var reach := float(spec[0]) * WS.M
	var f2 := Vector2(fwd.x, fwd.z).normalized()
	var best: WK.Walker = null
	var bd := INF
	for o: WK.Walker in wk.walkers:
		if not _free(o):
			continue
		var q := o.pos + o.vis_off
		var d := Vector2(q.x - p.x, q.z - p.z)
		var dist := d.length()
		if dist > reach or dist < 1e-6 or d.dot(f2) < float(spec[1]) * dist:
			continue
		if float(spec[2]) <= 0.0:
			if dist < bd:
				bd = dist
				best = o
		elif out.size() < ANSWER_MAX and _rng.randf() < float(spec[2]):
			out.append(o)
	if best != null:
		out.append(best)
	for o: WK.Walker in out:
		var r := _new(o)
		r.src = p
		r.delay = _rng.randf_range(0.3, 0.8)
		r.steps = [["place", spec[3], float(spec[4])]]
	return out


## True when o can start a reaction: drawn near, not talking to the player, not reacting.
func _free(o: WK.Walker) -> bool:
	return not (o.dead or o.far or o.state == "hidden" or o.hold or _active.has(o.id))


func _new(w: WK.Walker) -> Reaction:
	var r := Reaction.new()
	r.w = w
	r.speed = w.speed
	_active[w.id] = r
	return r


## Starts r's next step, or gives the walker its own state back when none is left.
func _next_step(r: Reaction) -> void:
	var w := r.w
	if r.was.is_empty():
		# A chat is over (the other one walks on by itself).
		r.was = "walk" if w.state == "chat" else w.state
		w.chat_with = null
	if r.steps.is_empty():
		_finish(r)
		return
	var st: Array = r.steps.pop_front()
	r.mode = str(st[0])
	r.left = float(st[2])
	if r.mode == "run":
		w.state = r.was
		w.react = &"run"
		w.speed = r.speed * RUN_F
		if w.on_leg:
			# Off the network the run starts where the blow left the walker: easing its drawn
			# offset out instead would slide it back toward the blow as it runs.
			w.pos += w.vis_off
			w.vis_off = Vector3.ZERO
		wk.turn_from(w, r.src)
		return
	w.state = "react"
	w.react = st[1]
	w.react_t = HOLD_AT if r.mode == "held" else 0.0
	w.react_rate = 0.0 if r.mode == "held" else 1.0
	w.v = 0.0
	w.vel = Vector3.ZERO
	if r.mode == "fight":
		r.blow_t = -1.0
		r.pause = FIGHT_FIRST


func _finish(r: Reaction) -> void:
	var w := r.w
	_drop(r)
	w.vis_tilt = 0.0
	_active.erase(w.id)
	w.react = &""
	w.react_rate = 1.0
	w.speed = r.speed
	if w.state == "react":
		w.state = r.was if not r.was.is_empty() else "walk"


func step(dt: float) -> void:
	clock += dt
	for r: Reaction in _active.values():
		var w := r.w
		if w.dead or (r.mode in ["place", "back", "fight", "held", "drag"] and w.state != "react"):
			# Gone, or taken on by something else (a trip set off): let go.
			_finish(r)
			continue
		if r.delay > 0.0:
			r.delay -= dt
			if r.delay <= 0.0:
				_next_step(r)
			continue
		_drop(r)
		if r.mode != "drag":
			_slide(r, dt)
			_throw(r, dt)
		var over := false
		match r.mode:
			"place":
				over = _place(r, dt)
			"drag":
				over = _drag(r, dt)
			"back":
				over = _back(r, dt)
			"fight":
				over = _fight(r, dt)
			"held":
				over = _held(r, dt)
			_:
				r.left -= dt
				over = r.left <= 0.0 or w.state != "walk"
		if over:
			_next_step(r)


## Stands and plays the step's clip (turning to face src once a one-shot is over); true when done.
func _place(r: Reaction, dt: float) -> bool:
	var w := r.w
	r.left -= dt
	w.react_t += dt
	w.vis_v = 0.0
	w.gait = move_toward(w.gait, 0.0, dt * 4.0)
	if w.react not in ONCE:
		var d := r.src - (w.pos + w.vis_off)
		if Vector2(d.x, d.z).length_squared() > 1e-10:
			w.yaw = lerp_angle(w.yaw, atan2(d.x, d.z), minf(1.0, dt * 5.0))
	return r.left <= 0.0


## Walks back to the walker's own place (its drawn offset to nothing); true once there.
func _back(r: Reaction, dt: float) -> bool:
	var w := r.w
	r.left -= dt
	var off := Vector2(w.vis_off.x, w.vis_off.z)
	var d := BACK_V * dt
	if off.length() <= d or r.left <= 0.0:
		w.vis_off = Vector3.ZERO
		w.vis_v = 0.0
		return true
	var dir := -off.normalized()
	_set_feet(w, w.pos + w.vis_off + Vector3(dir.x, 0.0, dir.y) * d)
	w.yaw = lerp_angle(w.yaw, atan2(dir.x, dir.y), minf(1.0, dt * 8.0))
	w.vis_v = BACK_V
	w.gait = move_toward(w.gait, 1.0, dt * 4.0)
	w.phase += d / (0.75 * WS.M) * PI
	return false


## In the hero's hands: the feet follow the hold (dragged along, stopped by walls and posts), the
## body turned to the hero, the clip stopped; true once let go or HOLD_S is up (breaking free).
func _held(r: Reaction, dt: float) -> bool:
	var w := r.w
	r.left -= dt
	r.hold_left = r.left
	var p := w.pos + w.vis_off
	var move := Vector3(r.hold_p.x - p.x, 0.0, r.hold_p.z - p.z)
	var q := p + move
	if collision != null:
		q = collision.move_body(p, move, BODY_R, BODY_H, WS.STEP_HEIGHT)
	_set_feet(w, q)
	w.vis_v = 0.0
	w.gait = 0.0
	w.yaw = lerp_angle(w.yaw, r.hold_yaw, minf(1.0, dt * 12.0))
	if r.left <= 0.0:
		r.held = false
	return not r.held


## Fighting back: squares up to the hero, closes in to FIGHT_REACH and throws a punch whenever the
## pause is over. Over (true) once the punch under way is done and the hero cannot be fought, is
## FIGHT_LOST away or the step's time is up.
func _fight(r: Reaction, dt: float) -> bool:
	var w := r.w
	r.left -= dt
	var me := w.pos + w.vis_off
	var to := Vector3(wk.player_pos.x - me.x, 0.0, wk.player_pos.z - me.z)
	var dist := to.length()
	if r.blow_t >= 0.0:
		_punch(r, dt, dist)
		return false
	if not hero_open or dist > FIGHT_LOST or r.left <= 0.0:
		return true
	var dir := to / maxf(dist, 1e-6)
	w.yaw = lerp_angle(w.yaw, atan2(dir.x, dir.z), minf(1.0, dt * 10.0))
	r.pause -= dt
	if dist > FIGHT_REACH + FIGHT_SLACK:
		_close_in(r, dir, dist - FIGHT_REACH, dt)
		return false
	w.react = &""
	w.vis_v = 0.0
	w.gait = move_toward(w.gait, 0.0, dt * 4.0)
	if r.pause <= 0.0:
		r.blow_t = 0.0
		w.react = FIGHT_BLOWS[r.blow][0]
		w.react_t = 0.0
		if on_wind_up.is_valid() and dist <= FIGHT_HIT:
			on_wind_up.call(w.id, _fist(w), float(FIGHT_BLOWS[r.blow][1]))
	return false


## Runs at the hero from afar and walks the last metres (by at most room), stopped by walls and
## posts.
func _close_in(r: Reaction, dir: Vector3, room: float, dt: float) -> void:
	var w := r.w
	var run := room > FIGHT_RUN
	var v := r.speed * (RUN_F if run else 1.0)
	var d := minf(v * dt, room)
	var p := w.pos + w.vis_off
	var q := p + dir * d
	if collision != null:
		q = collision.move_body(p, dir * d, BODY_R, BODY_H, WS.STEP_HEIGHT)
	_set_feet(w, q)
	w.react = &"run" if run else &""
	w.vis_v = v
	w.gait = move_toward(w.gait, 1.0, dt * 4.0)
	w.phase += d / (0.75 * WS.M) * PI


## The punch under way: at its contact time it reaches a hero still within FIGHT_HIT in the cone
## ahead (_reach_hero); once the clip has played, the next punch of the pair waits a pause.
func _punch(r: Reaction, dt: float, dist: float) -> void:
	var w := r.w
	var spec: Array = FIGHT_BLOWS[r.blow]
	var t0 := r.blow_t
	r.blow_t += dt
	w.react_t += dt
	w.vis_v = 0.0
	var fwd := Vector3(sin(w.yaw), 0.0, cos(w.yaw))
	var me := w.pos + w.vis_off
	var to := Vector3(wk.player_pos.x - me.x, 0.0, wk.player_pos.z - me.z)
	var contact := float(spec[1])
	var reach := hero_open and dist <= FIGHT_HIT and to.dot(fwd) >= FIGHT_CONE * dist
	if t0 < contact and r.blow_t >= contact and reach:
		_reach_hero(w, float(spec[2]))
	if r.blow_t >= float(spec[3]):
		r.blow_t = -1.0
		r.blow = (r.blow + 1) % FIGHT_BLOWS.size()
		r.pause = _rng.randf_range(FIGHT_GAP.x, FIGHT_GAP.y)
		w.react = &""


## w's punch of strength reaches the hero: countered (on_hero_parry), it misses; else it lands
## (on_hero_hit).
func _reach_hero(w: WK.Walker, strength: float) -> void:
	var at := _fist(w)
	if on_hero_parry.is_valid() and bool(on_hero_parry.call(w.id, at)):
		punches_parried += 1
		return
	punches_landed += 1
	if on_hero_hit.is_valid():
		on_hero_hit.call(at, strength, Vector3(sin(w.yaw), 0.0, cos(w.yaw)) * FIGHT_PUSH)


## Where w's fist lands: FIST ahead of and up from its drawn feet.
static func _fist(w: WK.Walker) -> Vector3:
	var fwd := Vector3(sin(w.yaw), 0.0, cos(w.yaw))
	return w.pos + w.vis_off + fwd * (FIST.x * WS.M) + Vector3(0.0, FIST.y * WS.M, 0.0)


## True while w is fighting the hero (closing in or punching).
func fighting(w: WK.Walker) -> bool:
	var r: Reaction = _active.get(w.id)
	return r != null and r.mode == "fight"


## Moves the drawn offset on along the blow's slide (easing out), stopped by walls and posts.
func _slide(r: Reaction, dt: float) -> void:
	if r.slide_t >= r.slide_s:
		return
	var a := _slide_k(r, r.slide_t)
	r.slide_t = minf(r.slide_t + dt, r.slide_s)
	var move := r.slide * (_slide_k(r, r.slide_t) - a)
	var p := r.w.pos + r.w.vis_off
	var q := p + move
	if collision != null:
		q = collision.move_body(p, move, BODY_R, BODY_H, WS.STEP_HEIGHT)
	_set_feet(r.w, q)


## How much of its slide r has covered t s in: eased out, or for a throw at a steady pace through
## the air and eased out over the skid.
static func _slide_k(r: Reaction, t: float) -> float:
	if r.air <= 0.0:
		return _ease(t / r.slide_s)
	if t <= r.air:
		return (1.0 - r.skid) * t / r.air
	return 1.0 - r.skid + r.skid * _ease((t - r.air) / maxf(r.slide_s - r.air, 1e-3))


## Lifts the drawn feet along a knock-down's throw: one arc up and down, then a small bounce; a
## throw tips the body back on the way.
func _throw(r: Reaction, dt: float) -> void:
	if r.lift <= 0.0 and r.bump == 0.0:
		return
	r.fly_t += dt
	var h := throw_height(r.fly_t, r.lift, r.fly_s)
	r.w.vis_off.y += h
	r.bump = h
	r.w.vis_tilt = -r.tilt * sin(PI * r.fly_t / r.fly_s) if r.fly_t < r.fly_s else 0.0
	if h == 0.0 and r.fly_t > r.fly_s:
		r.lift = 0.0


## Dragged out of a car: w is drawn on from the seat out over the sill to beside the door, turning
## to face the car and tipping back as it comes; true once out.
func _drag(r: Reaction, dt: float) -> bool:
	var w := r.w
	r.left -= dt
	var x := clampf(1.0 - r.left / DRAG_S, 0.0, 1.0)
	var k := smoothstep(0.0, 1.0, x)
	var at := (r.drag[0] as Vector3).lerp(r.drag[1], k) + Vector3(0.0, DRAG_LIFT * sin(PI * x), 0.0)
	w.vis_off = at - w.pos
	w.yaw = lerp_angle(float(r.drag[2]), float(r.drag[3]), k)
	w.vis_tilt = -DRAG_TILT * sin(PI * x)
	w.vis_v = 0.0
	return r.left <= 0.0


## Takes the throw's height back out of the drawn feet (before they move on the ground).
func _drop(r: Reaction) -> void:
	r.w.vis_off.y -= r.bump
	r.bump = 0.0


## How high a body thrown up to lift for fly seconds sits t seconds after the blow (0 once it has
## landed).
static func throw_height(t: float, lift: float, fly: float = FLY_S) -> float:
	if t < fly:
		var x := t / fly
		return 4.0 * lift * x * (1.0 - x)
	var b := (t - fly) / BOUNCE_S
	if b < 1.0:
		return 4.0 * lift * BOUNCE * b * (1.0 - b)
	return 0.0


static func _ease(x: float) -> float:
	return 1.0 - (1.0 - x) * (1.0 - x)


## Draws w's feet at q, on the ground there (off the curb into the road, say).
func _set_feet(w: WK.Walker, q: Vector3) -> void:
	var y := w.pos.y + w.vis_off.y
	if collision != null:
		var g := collision.walk_height(q)
		if not is_nan(g):
			y = g
	w.vis_off = Vector3(q.x - w.pos.x, y - w.pos.y, q.z - w.pos.z)


## Lane blocks for vehicles.gd: the people hit, until they walk or run on, as circles at their
## drawn feet (on a sidewalk they are clear of every lane).
func blocks() -> Array:
	var out: Array = []
	for r: Reaction in _active.values():
		if r.victim and r.mode != "run" and not r.w.dead:
			var q := r.w.pos + r.w.vis_off
			out.append([Vector2(q.x, q.z), Vector2.ZERO, -1.0, 0.0, Vector2.ZERO])
	return out


## Car-jacked w (just knocked down by the carjack's blow) is dragged out of the car first: drawn
## from from (its feet in the driver's seat, facing from_yaw) out to where the blow found it over
## DRAG_S in the sit pose, then it falls.
func drag_out(w: WK.Walker, from: Vector3, from_yaw: float) -> void:
	var r: Reaction = _active.get(w.id)
	if r == null or r.mode != "place" or not r.down:
		return
	r.steps.push_front(["place", w.react, r.left])
	r.drag = [from, w.pos + w.vis_off, from_yaw, w.yaw]
	r.mode = "drag"
	r.left = DRAG_S
	w.react = DRAG_CLIP
	w.react_t = DRAG_AT
	w.react_rate = 0.0
	w.yaw = from_yaw
	w.vis_off = from - w.pos


## True while w is knocked down (lying or getting up).
func is_down(w: WK.Walker) -> bool:
	var r: Reaction = _active.get(w.id)
	return r != null and r.down and r.w.react in [&"knockback", &"get_up"]


func count() -> int:
	return _active.size()


## Stages w playing clip from t seconds in, for secs (photos, tests). The caller releases its body
## so the next one starts at t.
func pose(w: WK.Walker, clip: StringName, t: float, secs: float = 60.0) -> void:
	var r: Reaction = _active.get(w.id)
	if r == null:
		r = _new(w)
	r.src = w.pos + Vector3(sin(w.yaw), 0.0, cos(w.yaw))
	r.steps = [["place", clip, secs]]
	r.delay = 0.0
	r.victim = clip in [&"knockback", &"get_up"]
	r.down = r.victim
	_next_step(r)
	w.react_t = t
	w.anim_clip = clip
	w.anim_t = t
