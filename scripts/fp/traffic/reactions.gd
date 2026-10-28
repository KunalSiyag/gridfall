extends RefCounted
## People hit in the street (docs/fp/ARCHITECTURE.md, Body actions): shoved or punched by the
## player, struck by the car they drive or dragged out of their own (carjack). A light blow makes
## the person reel (hit_chest, hit_head) and slide back a little; a hard one (DOWN), the
## HITS_DOWN-th punch in a row or a fast car knocks them down (knockback), and they lie a while
## before they get up (get_up). A car that runs them over where they lie shoves them along and
## leaves them down but up sooner. Then they shake their head or shout at whoever did it, run
## off, or walk back to where they were; some of those shoved or punched fight back instead
## (fight_back): they square up to the hero, close in and throw jabs and crosses (on_hero_hit)
## until the hero is down, gets away or drives off — each their own way (fight_tempers), fixed to
## who they are: one turns the hero's blows aside, one sidesteps round them while they wait, one
## calls friends over, one squares up and bolts, and a tough one leads with the cross and answers a
## blow at once. People within WITNESS_R who see it run off or shout too. While a walker stands
## where the blow left it its state is "react" (it keeps its edge and plan; the slide and the walk
## back move only its drawn offset), and a run gives it its own state back at RUN_F times its pace
## with the run clip. The hero may take hold of someone (grab): they hang in the hero's hands
## (hold_to) in HOLD_CLIP, reeling from blows without falling free, until let go (release), knocked
## down or HOLD_S is up, then react as to a shove. A punch thrown at the hero is announced as it
## starts (on_wind_up), holds back then snaps through its wind-up (counter_cues) and may be
## countered as it arrives (on_hero_parry). What follows a blow for the city (memory, mood, crews)
## is incidents.gd's.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const BS := preload("res://scripts/fp/traffic/body_spheres.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
## The scrap and the care for a body on the ground, split out of this file: fighting back, the
## tempers, counter cues and downed awareness live there. This file keeps the Reaction records
## and the after-blow plans; the layer borrows them (its back-link is a weakref). The aliases
## further down keep the old RE.* names working for tests and benches.
const FB := preload("res://scripts/fp/traffic/fight_back.gd")
## The crowd's answer to what the street sees and hears (the knock-down gasp, the horn startle),
## split out the same way; its constants stay under the old names via the alias below.
const CR := preload("res://scripts/fp/traffic/crowd_reacts.gd")
const TI := preload("res://scripts/fp/traffic/throw_impact.gd")
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
const HEAD_R := 0.14 * WS.M
## A fall sweeps the posed body this far past the drawn feet (the clip's tip, the lie's reach),
## so a knock-down's slide clamps them that much clear besides its capsule: the fall needs its
## own floor, and landing against the wall leaves the lie and the rise inside it.
const DOWN_REACH := 0.4 * WS.M
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
## The fight layer's constants under their old names, for the tests and benches that read them;
## fight_back.gd (FB) owns them now.
const FIGHT_ODDS := FB.FIGHT_ODDS
const FIGHT_BLOWS := FB.FIGHT_BLOWS
const FIGHT_REACH := FB.FIGHT_REACH
const WIND_RATE := FB.WIND_RATE
const CHECK_NEAR := FB.CHECK_NEAR
const STAND_OVER_S := FB.STAND_OVER_S
const BREAK_S := FB.BREAK_S
const T_PLAIN := FB.T_PLAIN
const T_GUARD := FB.T_GUARD
const T_DANCER := FB.T_DANCER
const T_CALLER := FB.T_CALLER
const T_BOLT := FB.T_BOLT
const T_BRUISER := FB.T_BRUISER
## The crowd layer's constants under their old names, for the tests that read them;
## crowd_reacts.gd (CR) owns them now.
const HORN_CD := CR.HORN_CD
## A knock-down throws the body (hit_feel flag): up LIFT (metres, by strength: a blow, a car), a
## blow's arc the FLY seconds by its strength (a car: FLY_S), back to the ground, then up BOUNCE
## of that again over BOUNCE_S. The harder a blow lands the higher and longer the body flies: a
## hook that finishes someone leaves the ground properly, a jab's third in a row barely does.
const LIFT := {"blow": Vector2(0.15, 0.45), "car": Vector2(0.3, 0.9)}
const FLY := Vector2(0.28, 0.42)
const FLY_S := 0.32
const BOUNCE := 0.2
const BOUNCE_S := 0.18
## A car runs over a body already lying there (hit(), cause "car"): the wheels shove it
## TRAMPLE_SLIDE metres (m, by strength) along the road over TRAMPLE_S, and whatever lie the
## knock-down had left it lies on only TRAMPLE_LIE seconds more (by strength) — it scrambles
## clear of the car.
const TRAMPLE_LIE := Vector2(1.2, 2.0)
const TRAMPLE_SLIDE := Vector2(0.2, 0.6)
const TRAMPLE_S := 0.45
## Held by the hero: HOLD_CLIP stopped HOLD_AT seconds in (recoiling); they break free after
## HOLD_S. A throw (hit's fling) slides the body over FLING_S.
const HOLD_CLIP := &"hit_chest"
const HOLD_AT := 0.12
const HOLD_S := 6.0
const FLING_S := 0.7
## A light blow tips the one hit back as they reel (hit_feel flag), up to TIP rad by strength:
## deeper for a punch (the head snapping back) than for a shove or a car's nudge (TIP_ELSE),
## played out over TIP_S of the reel clip's length and back upright by its end.
const TIP := {"punch": Vector2(0.06, 0.16), "shove": Vector2(0.04, 0.12)}
const TIP_ELSE := Vector2(0.04, 0.12)
const TIP_S := 0.7
## A directional finisher staggers before falling, by strength (seconds).
const STAGGER_S := Vector2(0.08, 0.16)
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
## and play the clip), "back" (walk back to the walker's own place), "run", "fight", "held" (in
## the hero's hands) or "check" (walk up to a body and lean over it, downed_awareness).
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
	var impact: Dictionary = {}  # a throw's predicted wall/prop strike {"at", "in"} (throw_impact)
	var impacted: bool = false  # the mid-flight rebound already played
	var tip: float = 0.0  # the reel's backward tip (rad, hit_feel); 0 for none
	var tip_t: float = 0.0  # seconds into the tip
	var tip_s: float = 0.0  # how long the tip takes to play out (s)
	var lean := Vector2(-1.0, 0.0)  # forward tip and side roll in the victim's own frame
	var stagger_left: float = 0.0  # seconds before a heavy melee blow's fall starts
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
	var aimed: bool = false  # the punch under way goes for the hero (so it was announced)
	var pause: float = 0.0  # seconds before the next punch may start
	var held: bool = false  # the hero holds them (grab), reeling from a blow included
	var hold_left: float = 0.0  # seconds before they break free
	var hold_p := Vector3.ZERO  # where the hero's hands put their feet
	var hold_yaw: float = 0.0
	var temper: int = 0  # their way of fighting (TEMPERS; fight_tempers)
	var strafe: int = 1  # a dancer's way round the hero (+1 or -1, by id parity)
	var called: bool = false  # a caller has already shouted their friends over
	var chip: float = 0.0  # how beaten a guard's guard is (guard_chip); the blow past 1 lands
	var broken: float = 0.0  # seconds the beaten guard stays down (guard_break): all blows land
	var slot_seq: int = -1  # arrival order among the hero's fighters (brawl_ring)
	var stood_over: bool = false  # the stand-over beat for a downed hero already played
	var checked: bool = false  # someone already came to look this one over (downed_awareness)
	var check_of: int = -1  # the checker: whose knock-down this one came to look at
	var check_hold: float = 0.0  # the checker: seconds left leaning over the body; 0 walking up


var wk: WK
var collision: CollisionWorld
var lengths: Dictionary = LENGTHS.duplicate()
var clock: float = 0.0
var _active: Dictionary = {}  # walker id -> Reaction
var _rng := RandomNumberGenerator.new()
## The fight layer (fight_back.gd): the scrap, the tempers, counter cues and the care for a body
## on the ground. Its state keeps the old names here through the properties below, so tests,
## benches and the traffic feature wire it as before.
var fight := FB.new()
## The crowd layer (crowd_reacts.gd): the knock-down gasp and the horn startle, its cooldowns its
## own.
var crowd := CR.new()
## The hero can be fought now (on foot and in control; traffic sets it every step), and who hears
## of a punch that lands on them: on_hero_hit(at, strength, push).
var hero_open: bool:
	get:
		return fight.hero_open
	set(value):
		fight.hero_open = value
## The hero is down on the ground now (traffic sets it every step beside hero_open;
## downed_awareness).
var hero_down: bool:
	get:
		return fight.hero_down
	set(value):
		fight.hero_down = value
var on_hero_hit: Callable:
	get:
		return fight.on_hero_hit
	set(value):
		fight.on_hero_hit = value
## Who hears of a punch thrown at the hero as it starts: on_wind_up(walker id, fist, seconds until
## it lands); and who may counter it as it lands: on_hero_parry(walker id, fist) -> true when it
## is countered (it then misses).
var on_wind_up: Callable:
	get:
		return fight.on_wind_up
	set(value):
		fight.on_wind_up = value
var on_hero_parry: Callable:
	get:
		return fight.on_hero_parry
	set(value):
		fight.on_hero_parry = value
## The posed body's collision points at a base position (people.gd body_spheres: [feet, torso,
## head]); set by the traffic feature. Without it only the feet capsule is kept clear, and the
## fall, the lie and the get-up pose the head and torso past whatever stopped the feet.
var body_extent: Callable
## The moving car bodies near a point, as [xz centre, yaw, Vector2(half width, half length),
## y bottom, y top]; set by the traffic feature. Without it a body thrown or slid into a real
## car lies inside the drawn vehicle: the static world the press-out reads holds no cars.
var cars_near: Callable
## The share who fight back, by cause (test hook), and the punches that landed on the hero or
## were countered.
var fight_odds: Dictionary:
	get:
		return fight.fight_odds
	set(value):
		fight.fight_odds = value
## Walker id -> their temper among TEMPERS (a test hook, overriding the identity hash), and the
## share of the hero's blows a guard turns aside (a test hook too).
var fight_temper: Dictionary:
	get:
		return fight.fight_temper
	set(value):
		fight.fight_temper = value
var guard_share: float:
	get:
		return fight.guard_share
	set(value):
		fight.guard_share = value
var punches_landed: int:
	get:
		return fight.punches_landed
	set(value):
		fight.punches_landed = value
var punches_parried: int:
	get:
		return fight.punches_parried
	set(value):
		fight.punches_parried = value


func setup(p_wk: WK, p_collision: CollisionWorld, seed: int) -> void:
	wk = p_wk
	collision = p_collision
	_rng.seed = seed * 9157 + 5
	_active.clear()
	fight.wk = wk
	fight.collision = collision
	fight.rng = _rng
	fight.active = _active
	fight.new_reaction = _new
	fight.is_free = _free
	fight.after_plan = _after
	crowd.wk = wk
	crowd.rng = _rng
	crowd.new_reaction = _new
	crowd.is_free = _free
	crowd.active = _active
	crowd.now = func() -> float: return clock
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
## "shove", "punch", "car" or "carjack"; fling (metres, NOT world units like the rest) > 0 throws
## a body it knocks down that far. Held
## (grab) and not knocked down, w reels and hangs on. A car that runs w over where it already lies
## (_trample) shoves it along and leaves it down but up sooner. A guarded fighter may turn a punch
## or a shove aside instead (fight_tempers). Returns {"down": bool, "clip": StringName}, or {}
## when w cannot take one now (hidden, in a conversation, in the air, or lying there for anything
## but a car).
func hit(
	w: WK.Walker, src: Vector3, push: Vector3, strength: float, cause: String, fling: float = 0.0
) -> Dictionary:
	if cause == "car" and is_down(w):
		return _trample(w, src, push, strength)
	var r := _take(w)
	if r == null:
		return {}
	r.victim = true
	r.delay = 0.0
	r.src = src
	if fight.turned_aside(r, cause, strength):
		var gclip := fight.guarded_plan(r, cause)
		_next_step(r)
		return {"down": false, "clip": gclip, "guarded": true, "disarm": fight.last_disarm}
	r.impact = {}
	r.impacted = false
	r.hits = r.hits + 1 if clock - r.last < HITS_S else 1
	r.last = clock
	var d := _away(w, src, push)
	r.down = strength >= DOWN or (cause == "punch" and r.hits >= HITS_DOWN)
	# Directional melee keeps the victim's facing through the stagger; a box is dropped.
	var directional := FeatureFlags.enabled("directional_hits") and cause in ["punch", "shove"]
	if not directional or fling > 0.0:
		w.yaw = atan2(-d.x, -d.z)
	w.extra = 0 if w.extra == 1 else w.extra
	var clip: StringName
	if r.down:
		clip = _plan_down(r, d, strength, cause, fling)
	else:
		clip = _plan_reel(r, d, strength, cause)
	_directional_stagger(r, d, strength, directional and fling <= 0.0)
	if r.held:
		_keep_held(r)
	r.steps.append_array(_after(r, cause))
	if r.down:
		fight.send_checker(r)
	r.slide_t = 0.0
	r.fly_t = 0.0
	_next_step(r)
	if r.impact.is_empty():
		return {"down": r.down, "clip": clip}
	return {"down": r.down, "clip": clip, "impact": r.impact}


## Tip and roll away from the blow in the unchanged body's frame. Finishers get a short reel
## before their fall; throws, cars and the flag-off path retain immediate launch.
func _directional_stagger(r: Reaction, d: Vector3, strength: float, on: bool) -> void:
	r.lean = Vector2(-1.0, 0.0)
	r.stagger_left = 0.0
	if not on:
		return
	var s := clampf(strength, 0.0, 1.0)
	var forward := Vector3(sin(r.w.yaw), 0.0, cos(r.w.yaw))
	var right := Vector3(-forward.z, 0.0, forward.x)
	r.lean = Vector2(d.dot(forward), d.dot(right))
	if not r.down:
		return
	var seconds := lerpf(STAGGER_S.x, STAGGER_S.y, s)
	r.stagger_left = seconds
	r.steps.push_front(["place", &"hit_chest", seconds])
	r.tip = lerpf(0.12, 0.3, s)
	r.tip_t = 0.0
	r.tip_s = seconds * 2.0


## A car runs w over where it lies (hit(), cause "car", already knocked down): the wheels shove
## it along push — however it lies, its facing kept — and it is up sooner, scrambling clear of the
## car; run over as it rises it is flattened again, the fall playing out once more. Returns hit()'s
## shape, {} while it is still in the air. The street reacts as for any car hit (hit_walker, this
## one's caller, carries on the same: witnesses, incidents, the bus).
func _trample(w: WK.Walker, src: Vector3, push: Vector3, strength: float) -> Dictionary:
	var r: Reaction = _active.get(w.id)
	if r == null or not r.down or w.dead or r.mode != "place":
		return {}
	if r.lift > 0.0 and r.fly_t < r.fly_s:
		return {}
	var s := clampf(strength, 0.0, 1.0)
	r.hits += 1
	r.last = clock
	r.src = src
	var lie := lerpf(TRAMPLE_LIE.x, TRAMPLE_LIE.y, s)
	if r.w.react == &"get_up":
		r.steps = [
			["place", &"knockback", float(lengths[&"knockback"]) + lie],
			["place", &"get_up", float(lengths[&"get_up"])],
		]
		r.steps.append_array(_after(r, "car"))
		_next_step(r)
	else:
		# Lying there: whatever lie the knock-down had left, it is up in the trample's own.
		r.left = minf(r.left, float(lengths[&"knockback"]) + lie)
	r.lift = 0.0
	r.air = 0.0
	r.tip = 0.0
	r.slide = _away(w, src, push) * (lerpf(TRAMPLE_SLIDE.x, TRAMPLE_SLIDE.y, s) * WS.M)
	r.slide_t = 0.0
	r.slide_s = TRAMPLE_S
	return {"down": true, "clip": &"knockback"}


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
	var s := clampf(strength, 0.0, 1.0)
	var lie := lerpf(2.5, 6.0, strength) if car else _rng.randf_range(1.2, 2.4)
	var m := lerpf(1.5, 4.0, strength) if car else lerpf(0.8, 1.4, strength)
	r.steps = [
		["place", &"knockback", float(lengths[&"knockback"]) + lie],
		["place", &"get_up", float(lengths[&"get_up"])],
	]
	r.slide = d * ((fling if fling > 0.0 else m) * WS.M)
	r.slide_s = FLING_S if fling > 0.0 else 0.55
	var lift: Vector2 = LIFT["car" if car else "blow"]
	r.lift = lerpf(lift.x, lift.y, s) * WS.M
	r.fly_s = FLY_S if car else lerpf(FLY.x, FLY.y, s)
	r.air = 0.0
	r.tilt = 0.0
	r.tip = 0.0
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
		r.impact = TI.impact_ahead(
			collision,
			r.w.pos + r.w.vis_off,
			r.slide * (1.0 - r.skid),
			r.air,
			BODY_R + DOWN_REACH,
			BODY_H
		)
	return &"knockback"


## A light blow: reeling back (head for a punch, chest otherwise; the other one when the same clip
## is playing, so a second blow shows), the body tipped back along the blow (hit_feel).
func _plan_reel(r: Reaction, d: Vector3, strength: float, cause: String) -> StringName:
	var clip: StringName = &"hit_head" if cause == "punch" else &"hit_chest"
	if r.w.react == clip:
		clip = &"hit_chest" if clip == &"hit_head" else &"hit_head"
	var ln := float(lengths[clip])
	if FeatureFlags.enabled("directional_hits"):
		ln *= lerpf(0.9, 1.6, clampf(strength, 0.0, 1.0))
	r.steps = [["place", clip, ln]]
	r.lift = 0.0
	r.slide = d * (lerpf(0.25, 0.6, strength) * WS.M)
	r.slide_s = ln * 0.8
	var range: Vector2 = TIP.get(cause, TIP_ELSE)
	r.tip = (
		lerpf(range.x, range.y, clampf(strength, 0.0, 1.0))
		if FeatureFlags.enabled("hit_feel")
		else 0.0
	)
	r.tip_t = 0.0
	r.tip_s = ln * TIP_S
	return clip


## What a victim does once the blow is over: shakes their head at a shove or shouts at a punch, a
## car or a carjack; after a punch or a carjack they run off when they can, else they walk back to
## their place. One who fights back shouts, goes for the hero, then walks back (straight back at
## it when hit mid-fight) — each their own way (fight_tempers, fight_back.gd's after_fight).
func _after(r: Reaction, cause: String) -> Array:
	var shout := ["place", &"no" if cause == "shove" else &"shout", _rng.randf_range(1.6, 2.6)]
	if not r.down and fight.fights_back(r, cause):
		return fight.after_fight(r)
	if (cause == "punch" or cause == "carjack") and _can_run(r):
		return [shout, fight.run_step()]
	return [shout, ["back", &"", 30.0]]


## w's temper among TEMPERS (fight_back.gd rolls it; kept here for the tests that pin it).
func temper_of(w: WK.Walker) -> int:
	return fight.temper_of(w)


## True when r's walker can run off: it was walking somewhere (an edge or a free leg).
func _can_run(r: Reaction) -> bool:
	var st := r.was if not r.was.is_empty() else r.w.state
	return (st == "walk" or st == "chat") and (r.w.edge != null or r.w.on_leg)


## People within WITNESS_R of w who see what happened to it (severity 0 a shove, 1 a punch, 2 a
## knock-down) and are not reacting already: some run off, some shout at src (shake their head at
## a shove). A knock-down with crowd_gasp on rocks the ones who stay back as one (GASP_TIP, no
## delay), once per crowd (GASP_CD/GASP_R). Returns them.
func witness(w: WK.Walker, src: Vector3, severity: int) -> Array:
	var out: Array = []
	var s := clampi(severity, 0, 2)
	var r2 := WITNESS_R * WITNESS_R
	var gasp := s == 2 and crowd.gasp_due(w.pos)
	var gasped := false
	for o: WK.Walker in wk.walkers:
		if o == w or not _free(o):
			continue
		if o.pos.distance_squared_to(w.pos) > r2 or _rng.randf() > SEE[s]:
			continue
		var r := _new(o)
		r.src = src
		r.delay = _rng.randf_range(0.2, 0.7)
		if _can_run(r) and _rng.randf() < FLEE[s]:
			r.steps = [fight.run_step()]
		else:
			r.steps = [["place", &"no" if s == 0 else &"shout", _rng.randf_range(1.5, 3.0)]]
			if gasp:
				# Rocks back as one with the crowd: at once, with a sharp backward tip.
				crowd.apply_gasp(r)
				gasped = true
		out.append(o)
	if gasped:
		crowd.noted_gasp(w.pos)
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


## A car horn sounded at src and carries radius (u; horn_street): the crowd answers
## (crowd_reacts.gd's startle; kept here for the traffic feature and the tests).
func startle(src: Vector3, radius: float, long: bool) -> Array:
	return crowd.startle(src, radius, long)


## True when o can start a reaction: drawn near, not talking to the player, not reacting.
func _free(o: WK.Walker) -> bool:
	return not (o.dead or o.far or o.state == "hidden" or o.hold or _active.has(o.id))


func _new(w: WK.Walker) -> Reaction:
	var r := Reaction.new()
	r.w = w
	r.speed = w.speed
	_active[w.id] = r
	return r


## Starts r's next step, or gives the walker its own state back when none is left. A step taking
## over from one under way ends a reel's tip (a knock-down's fall comes from its clip; a throw's
## tilt is applied anew each step).
func _next_step(r: Reaction) -> void:
	var w := r.w
	if not r.mode.is_empty():
		if r.tip_t > 0.0:
			r.tip = 0.0
		w.vis_tilt = 0.0
		w.vis_roll = 0.0
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
	if w.react == &"knockback" and not r.slide.is_zero_approx():
		w.yaw = atan2(-r.slide.x, -r.slide.z)
	w.react_t = HOLD_AT if r.mode == "held" else 0.0
	w.react_rate = 0.0 if r.mode == "held" else 1.0
	w.v = 0.0
	w.vel = Vector3.ZERO
	if r.mode == "fight":
		fight.begin(r)


func _finish(r: Reaction) -> void:
	var w := r.w
	_drop(r)
	w.vis_tilt = 0.0
	w.vis_roll = 0.0
	_active.erase(w.id)
	w.react = &""
	w.react_rate = 1.0
	w.speed = r.speed
	if w.state == "react":
		w.state = r.was if not r.was.is_empty() else "walk"


func step(dt: float) -> void:
	clock += dt
	crowd.step(dt)
	for r: Reaction in _active.values():
		var w := r.w
		if (
			w.dead
			or (
				r.mode in ["place", "back", "fight", "held", "drag", "check"] and w.state != "react"
			)
		):
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
			if r.mode == "place":
				_recoil(r, dt)
		var over := false
		match r.mode:
			"place":
				over = _place(r, dt)
			"drag":
				over = _drag(r, dt)
			"back":
				over = _back(r, dt)
			"fight":
				over = fight.step_fight(r, dt)
			"held":
				over = _held(r, dt)
			"check":
				over = fight.step_check(r, dt)
			_:
				r.left -= dt
				over = r.left <= 0.0 or w.state != "walk"
		if over:
			_next_step(r)
		if not w.dead:
			var cars: Array = (
				cars_near.call(w.pos + w.vis_off, 2.5 * WS.M) if cars_near.is_valid() else []
			)
			BS.press_out(w, body_extent, collision, cars)


## Stands and plays the step's clip (turning to face src once a one-shot is over); true when done.
func _place(r: Reaction, dt: float) -> bool:
	var w := r.w
	r.stagger_left = maxf(0.0, r.stagger_left - dt)
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


## True while w is fighting the hero (closing in or punching).
func fighting(w: WK.Walker) -> bool:
	var r: Reaction = _active.get(w.id)
	return r != null and r.mode == "fight"


## Moves the drawn offset on along the blow's slide (easing out), stopped by walls and posts.
func _slide(r: Reaction, dt: float) -> void:
	if r.stagger_left > 0.0 or r.slide_t >= r.slide_s:
		return
	var a := _slide_k(r, r.slide_t)
	r.slide_t = minf(r.slide_t + dt, r.slide_s)
	var move := r.slide * (_slide_k(r, r.slide_t) - a)
	var p := r.w.pos + r.w.vis_off
	var q := p + move
	if collision != null:
		var reach := BODY_R + (DOWN_REACH if r.down else 0.0)
		q = collision.move_body(p, move, reach, BODY_H, WS.STEP_HEIGHT)
		TI.rebound_if_blocked(r, p, move, q)
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
	if r.stagger_left > 0.0 or (r.lift <= 0.0 and r.bump == 0.0):
		return
	r.fly_t += dt
	var h := throw_height(r.fly_t, r.lift, r.fly_s)
	r.w.vis_off.y += h
	r.bump = h
	r.w.vis_tilt = -r.tilt * sin(PI * r.fly_t / r.fly_s) if r.fly_t < r.fly_s else 0.0
	if h == 0.0 and r.fly_t > r.fly_s:
		r.lift = 0.0


## Plays a reel's backward tip out (hit_feel): up through the blow's landing, back upright by the
## tip's end. Steps that are not a reel leave the body as they found it.
func _recoil(r: Reaction, dt: float) -> void:
	if r.tip <= 0.0:
		return
	r.tip_t += dt
	var k := clampf(r.tip_t / maxf(r.tip_s, 1e-3), 0.0, 1.0)
	var amount := r.tip * sin(PI * k)
	r.w.vis_tilt = r.lean.x * amount
	r.w.vis_roll = r.lean.y * amount
	if k >= 1.0:
		r.tip = 0.0
		r.w.vis_tilt = 0.0
		r.w.vis_roll = 0.0


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


## Draws w's feet at q, on the ground there (off the curb into the road, say): fight_back.gd's
## set_feet, kept here for the fall, the hold and the walk back that also use it.
func _set_feet(w: WK.Walker, q: Vector3) -> void:
	fight.set_feet(w, q)


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


## True once w has taken a knock-down, including its short stagger before falling.
func is_down(w: WK.Walker) -> bool:
	var r: Reaction = _active.get(w.id)
	return r != null and r.down and (r.stagger_left > 0.0 or r.w.react in [&"knockback", &"get_up"])


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
