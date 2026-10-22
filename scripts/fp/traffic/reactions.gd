extends RefCounted
## People hit in the street (docs/fp/ARCHITECTURE.md, Body actions): shoved or punched by the
## player, struck by the car they drive or dragged out of their own (carjack). A light blow makes
## the person reel (hit_chest, hit_head) and slide back a little; a hard one (DOWN), the
## HITS_DOWN-th punch in a row or a fast car knocks them down (knockback), and they lie a while
## before they get up (get_up). Then they shake their head or shout at whoever did it, run off, or
## walk back to where they were. People within WITNESS_R who see it run off or shout too. While a
## walker stands where the blow left it its state is "react" (it keeps its edge and plan; the
## slide and the walk back move only its drawn offset), and a run gives it its own state back at
## RUN_F times its pace with the run clip. What follows a blow for the city (memory, mood, crews)
## is incidents.gd's.

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


## One person reacting: the steps still to come, [mode, clip, seconds] with mode "place" (stand
## and play the clip), "back" (walk back to the walker's own place) or "run".
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
	var was: String = ""  # walker state to give back ("" until the first step starts)
	var speed: float = 0.0  # pace to give back after a run
	var victim: bool = false
	var down: bool = false
	var hits: int = 0
	var last: float = -INF


var wk: WK
var collision: CollisionWorld
var lengths: Dictionary = LENGTHS.duplicate()
var clock: float = 0.0
var _active: Dictionary = {}  # walker id -> Reaction
var _rng := RandomNumberGenerator.new()


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
## "shove", "punch", "car" or "carjack". Returns {"down": bool, "clip": StringName}, or {} when w
## cannot take one now (hidden, in a conversation, or down already).
func hit(w: WK.Walker, src: Vector3, push: Vector3, strength: float, cause: String) -> Dictionary:
	if w.dead or w.state == "hidden" or w.hold:
		return {}
	var r: Reaction = _active.get(w.id)
	if r != null and r.down:
		return {}
	if r == null:
		r = _new(w)
	elif r.mode == "run":
		w.speed = r.speed
		w.react = &""
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
	var clip := _plan_down(r, d, strength, cause) if r.down else _plan_reel(r, d, strength, cause)
	r.steps.append_array(_after(r, cause))
	r.slide_t = 0.0
	_next_step(r)
	return {"down": r.down, "clip": clip}


## Unit xz direction the blow pushes w: push, else away from src, else backward.
static func _away(w: WK.Walker, src: Vector3, push: Vector3) -> Vector3:
	var d := Vector3(push.x, 0.0, push.z)
	if d.length_squared() < 1e-12:
		d = Vector3(w.pos.x - src.x, 0.0, w.pos.z - src.z)
	if d.length_squared() < 1e-12:
		d = -Vector3(sin(w.yaw), 0.0, cos(w.yaw))
	return d.normalized()


## Knocked down: the fall and its slide (further for a car), a while on the ground, getting up.
func _plan_down(r: Reaction, d: Vector3, strength: float, cause: String) -> StringName:
	var car := cause == "car"
	var lie := lerpf(2.5, 6.0, strength) if car else _rng.randf_range(1.2, 2.4)
	var m := lerpf(1.5, 4.0, strength) if car else lerpf(0.8, 1.4, strength)
	r.steps = [
		["place", &"knockback", float(lengths[&"knockback"]) + lie],
		["place", &"get_up", float(lengths[&"get_up"])],
	]
	r.slide = d * (m * WS.M)
	r.slide_s = 0.55
	return &"knockback"


## A light blow: reeling back (head for a punch, chest otherwise; the other one when the same clip
## is playing, so a second blow shows).
func _plan_reel(r: Reaction, d: Vector3, strength: float, cause: String) -> StringName:
	var clip: StringName = &"hit_head" if cause == "punch" else &"hit_chest"
	if r.w.react == clip:
		clip = &"hit_chest" if clip == &"hit_head" else &"hit_head"
	var ln := float(lengths[clip])
	r.steps = [["place", clip, ln]]
	r.slide = d * (lerpf(0.25, 0.6, strength) * WS.M)
	r.slide_s = ln * 0.8
	return clip


## What a victim does once the blow is over: shakes their head at a shove or shouts at a punch, a
## car or a carjack; after a punch or a carjack they run off when they can, else they walk back to
## their place.
func _after(r: Reaction, cause: String) -> Array:
	var shout := ["place", &"no" if cause == "shove" else &"shout", _rng.randf_range(1.6, 2.6)]
	if (cause == "punch" or cause == "carjack") and _can_run(r):
		return [shout, _run_step()]
	return [shout, ["back", &"", 30.0]]


func _run_step() -> Array:
	return ["run", &"run", _rng.randf_range(4.0, 7.0)]


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
	w.react_t = 0.0
	w.v = 0.0
	w.vel = Vector3.ZERO


func _finish(r: Reaction) -> void:
	var w := r.w
	_active.erase(w.id)
	w.react = &""
	w.speed = r.speed
	if w.state == "react":
		w.state = r.was if not r.was.is_empty() else "walk"


func step(dt: float) -> void:
	clock += dt
	for r: Reaction in _active.values():
		var w := r.w
		if w.dead or (r.mode in ["place", "back"] and w.state != "react"):
			# Gone, or taken on by something else (a trip set off): let go.
			_finish(r)
			continue
		if r.delay > 0.0:
			r.delay -= dt
			if r.delay <= 0.0:
				_next_step(r)
			continue
		_slide(r, dt)
		var over := false
		match r.mode:
			"place":
				over = _place(r, dt)
			"back":
				over = _back(r, dt)
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


## Moves the drawn offset on along the blow's slide (easing out), stopped by walls and posts.
func _slide(r: Reaction, dt: float) -> void:
	if r.slide_t >= r.slide_s:
		return
	var a := _ease(r.slide_t / r.slide_s)
	r.slide_t = minf(r.slide_t + dt, r.slide_s)
	var move := r.slide * (_ease(r.slide_t / r.slide_s) - a)
	var p := r.w.pos + r.w.vis_off
	var q := p + move
	if collision != null:
		q = collision.move_body(p, move, BODY_R, BODY_H, WS.STEP_HEIGHT)
	_set_feet(r.w, q)


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
