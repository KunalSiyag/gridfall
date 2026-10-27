extends RefCounted
## The scrap and the care for a body on the ground: fighting back, the tempers, counter cues and
## downed awareness, split out of reactions.gd. reactions.gd keeps the Reaction records, the
## blow, the fall and the street watching; this layer borrows the records through the state
## setup() shares (the active table by reference, the _new/_free/_after callables) and stays
## untyped about Reaction so the two classes never preload each other. reactions.gd drives it:
## begin() from _next_step, step_fight()/step_check() from the step match, the rest from hit(),
## witness() and _after().

const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")

## Fighting back (fight_back): the share of those shoved or punched (and not knocked down) who
## do, by cause (fight_odds starts as this); how long a fight may last (s); how close they come
## (feet to feet; within FIGHT_SLACK of it counts), from how far they run there and beyond how
## far they give up.
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
## A punch at the hero holds its clip back at WIND_RATE through the first half of the run to
## contact, then plays at 2 - WIND_RATE, so the clip arrives with the blow's own timing
## (counter_cues): the wind-up reads, the strike snaps, the counter window never moves.
const WIND_RATE := 0.5
## A punch lands on the hero within FIGHT_HIT (feet to feet) inside the cone ahead (the cosine),
## from the fist FIST ahead and up (metres), and pushes them on at FIGHT_PUSH (u/s).
const FIGHT_HIT := 1.25 * WS.M
const FIGHT_CONE := 0.5
const FIST := Vector2(0.5, 1.45)
const FIGHT_PUSH := 1.5 * WS.M
## How a fighter fights (fight_tempers), in pick order with their shares: a temper is fixed to
## who the fighter is — their walker id and resident id hashed into the shares, so the same
## person always fights the same way whatever the order of things around them. One plain; a
## guard turns GUARD_SHARE of the hero's blows that reach them while the scrap is theirs; a
## dancer sidesteps their way (by id parity) round the ring at DANCE_W (rad/s); a caller brings
## at most CALL_MAX of those near enough to see in with them; a bolt's scrap lasts BOLT_S
## before they run; a bruiser leads with the cross and answers a blow the moment it lands.
const TEMPERS: Array[String] = ["plain", "guard", "dancer", "caller", "bolt", "bruiser"]
const TEMPER_SHARE: Array[float] = [0.34, 0.18, 0.16, 0.12, 0.1, 0.1]
const T_PLAIN := 0
const T_GUARD := 1
const T_DANCER := 2
const T_CALLER := 3
const T_BOLT := 4
const T_BRUISER := 5
const GUARD_SHARE := 0.45
const DANCE_W := 0.7
const CALL_MAX := 2
const BOLT_S := 2.5
## A guard's guard wears out (guard_chip): every blow turned aside chips it by CHIP_HIT plus
## CHIP_K times the blow's strength, and the one that takes it past 1 lands in full instead.
const CHIP_HIT := 0.26
const CHIP_K := 0.2
## Downed awareness (downed_awareness): a blow that leaves someone down brings the nearest free
## onlooker within CHECK_R over to look — they come within CHECK_NEAR (feet to feet), lean in
## (rad, + forward) with a slow head shake for CHECK_S, then walk on; once for each knock-down.
## A fighter whose hero goes down stands over them a beat (STAND_OVER_S) before walking off.
## CHECK_CAP bounds the walk over.
const CHECK_R := 6.0 * WS.M
const CHECK_NEAR := 0.8 * WS.M
const CHECK_S := 2.4
const CHECK_LEAN := 0.3
const CHECK_CAP := 9.0
const STAND_OVER_S := 1.3
## A walker's own speed times this is their run; the fighter capsule radii (u) handed to the
## collision world. Both as reactions.gd (its RUN_F, BODY_R and BODY_H).
const RUN_F := 2.6
const BODY_R := 0.25 * WS.M
const BODY_H := 1.7 * WS.M
## How near a brawler's call for friends reaches, as reactions.gd's WITNESS_R.
const WITNESS_R := 8.0 * WS.M

## The hero can be fought now (on foot and in control; traffic sets it every step), and who hears
## of a punch that lands on them: on_hero_hit(at, strength, push).
var hero_open: bool = false
## The hero is down on the ground now (traffic sets it every step beside hero_open;
## downed_awareness).
var hero_down: bool = false
var on_hero_hit: Callable
## Who hears of a punch thrown at the hero as it starts: on_wind_up(walker id, fist, seconds until
## it lands); and who may counter it as it lands: on_hero_parry(walker id, fist) -> true when it
## is countered (it then misses).
var on_wind_up: Callable
var on_hero_parry: Callable
## The share who fight back, by cause (test hook), and the punches that landed on the hero or
## were countered.
var fight_odds: Dictionary = FIGHT_ODDS.duplicate()
## Walker id -> their temper among TEMPERS (a test hook, overriding the identity hash), and the
## share of the hero's blows a guard turns aside (a test hook too).
var fight_temper: Dictionary = {}
var guard_share := GUARD_SHARE
var punches_landed: int = 0
var punches_parried: int = 0

var wk: WK
var collision: CollisionWorld
var rng: RandomNumberGenerator
## reactions.gd's live state, shared at setup: walker id -> Reaction of everyone down or
## reacting, the spawner of a Reaction for a walker (_new), the "may start a reaction" test
## (_free) and the after-blow planner (_after, for a turned-aside blow's scrap going on).
var active: Dictionary
var new_reaction: Callable
var is_free: Callable
var after_plan: Callable


## w's temper among TEMPERS: the test pin (fight_temper) wins, else it is fixed to who w is
## (fight_tempers) — their id and resident id hashed into the shares, so the same person always
## fights the same way whatever the order of things around them. Plain without the flag.
func temper_of(w: WK.Walker) -> int:
	var forced := int(fight_temper.get(w.id, -1))
	if forced >= 0:
		return forced
	if not FeatureFlags.enabled("fight_tempers"):
		return T_PLAIN
	var x := float(absi(hash("%d|%s" % [w.id, w.resident_id]) % 1000)) / 1000.0
	var acc := 0.0
	for i: int in TEMPERS.size():
		acc += TEMPER_SHARE[i]
		if x < acc:
			return i
	return T_PLAIN


## A fighter's temper, and their way round the hero, fixed; a fresh scrap starts with a whole
## guard (guard_chip).
func arm(r) -> void:
	r.temper = temper_of(r.w)
	r.strafe = 1 if r.w.id % 2 == 0 else -1
	r.chip = 0.0


## True when r's walker fights the hero back: always once they have, else by fight_odds for the
## cause while the hero can be fought. A fighter's temper is fixed the moment they square up.
func fights_back(r, cause: String) -> bool:
	if not r.fighter and hero_open and FeatureFlags.enabled("fight_back"):
		r.fighter = rng.randf() < float(fight_odds.get(cause, 0.0))
		if r.fighter and FeatureFlags.enabled("fight_tempers"):
			arm(r)
	return r.fighter


## True when the hero's blow lands on a guarded fighter's guard instead (fight_tempers): the
## scrap is still theirs (fighting, or waiting to) and they turn guard_share of the blows that
## reach them aside. Nothing of it counts: no reel back, no slide, nothing toward the knock-down.
## But the guard wears (guard_chip): each blow turned aside chips it, and the one that takes the
## chip past 1 lands in full.
func turned_aside(r, cause: String, strength: float) -> bool:
	if not r.fighter or r.held or cause not in ["punch", "shove"]:
		return false
	if not FeatureFlags.enabled("fight_tempers") or r.temper != T_GUARD:
		return false
	if r.mode != "fight":
		var in_it := false
		for s: Array in r.steps:
			if str(s[0]) == "fight":
				in_it = true
		if not in_it:
			return false
	if rng.randf() >= guard_share:
		return false
	if FeatureFlags.enabled("guard_chip"):
		r.chip += CHIP_HIT + CHIP_K * clampf(strength, 0.0, 1.0)
		if r.chip >= 1.0:
			# The guard is beaten: this one lands.
			return false
	return true


## The blow they turned aside (fight_tempers): a short duck behind the guard, then the scrap goes
## on as it was. Plans the steps; the caller (reactions.hit) starts them.
func guarded_plan(r, cause: String) -> StringName:
	var ln := 0.3
	r.steps = [["place", &"hit_chest", ln]]
	r.steps.append_array(after_plan.call(r, cause))
	r.lift = 0.0
	r.slide = Vector3.ZERO
	r.slide_s = 0.0
	r.slide_t = 0.0
	r.fly_t = 0.0
	r.tip = 0.12
	r.tip_t = 0.0
	r.tip_s = ln
	r.lean = Vector2(0.5, 0.0)
	return &"hit_chest"


## A fighter's plan once the blow is over (fight_tempers): a caller shouts their call longer and
## drafts friends into it; the scrap itself and what follows it are fight_steps.
func after_fight(r) -> Array:
	var steps := fight_steps(r)
	if r.mode == "fight":
		return steps
	var temps := FeatureFlags.enabled("fight_tempers")
	if temps and r.temper == T_CALLER and not r.called:
		r.called = true
		call_friends(r)
	var entry := 1.2 if temps and r.temper == T_CALLER else 0.8
	return [["place", &"shout", entry], steps[0], steps[1]]


## The scrap and what follows it, by temper (fight_tempers): a bolt's fight is short and ends in
## them running off; anyone else's may run its course and ends in a walk back.
func fight_steps(r) -> Array:
	var s := FIGHT_S
	var away: Array = ["back", &"", 30.0]
	if FeatureFlags.enabled("fight_tempers") and r.temper == T_BOLT:
		s = BOLT_S
		away = run_step()
	return [["fight", &"", s], away]


## A caller drafts friends into the scrap (fight_tempers): up to CALL_MAX of the people around
## within WITNESS_R who are free shout with them, square up and join in, each their own way.
func call_friends(r) -> void:
	var joined := 0
	for o: WK.Walker in wk.walkers:
		if joined >= CALL_MAX:
			return
		if o == r.w or not is_free.call(o):
			continue
		if o.pos.distance_squared_to(r.w.pos) > WITNESS_R * WITNESS_R:
			continue
		var f = new_reaction.call(o)
		f.src = r.src
		f.delay = rng.randf_range(0.2, 0.7)
		arm(f)
		f.fighter = true
		f.steps = [["place", &"shout", 0.6]]
		f.steps.append_array(fight_steps(f))
		joined += 1


func run_step() -> Array:
	return ["run", &"run", rng.randf_range(4.0, 7.0)]


## Sends the nearest free onlooker within CHECK_R to look r's downed victim over
## (downed_awareness): once for each knock-down, and never one of the fight's own. The checker
## walks up beside the body, leans in a moment, then walks on (the "check" step, step_check).
func send_checker(r) -> void:
	if not FeatureFlags.enabled("downed_awareness") or r.checked:
		return
	var at: Vector3 = r.w.pos + r.w.vis_off
	var best: WK.Walker = null
	var bd := CHECK_R
	for o: WK.Walker in wk.walkers:
		if o == r.w or not is_free.call(o):
			continue
		var d := Vector2(o.pos.x - at.x, o.pos.z - at.z).length()
		if d < bd:
			bd = d
			best = o
	if best == null:
		return
	r.checked = true
	var c = new_reaction.call(best)
	c.src = at
	c.check_of = r.w.id
	c.delay = rng.randf_range(0.4, 0.9)
	c.steps = [["check", &"", CHECK_CAP]]


## The checker walks up beside the body they came for, then leans over it with a slow head shake
## (CHECK_S) and walks on. Over at once when the one they came for is up again or gone. A
## hand's width past CHECK_NEAR counts as arrived: the walk clamps at the ring, and without the
## slack a landing exactly on it would never tip into the lean.
func step_check(r, dt: float) -> bool:
	r.left -= dt
	var v = active.get(r.check_of)
	if v == null or not v.down:
		return true
	var w: WK.Walker = r.w
	var at: Vector3 = v.w.pos + v.w.vis_off
	var me := w.pos + w.vis_off
	var to := Vector3(at.x - me.x, 0.0, at.z - me.z)
	var dist := to.length()
	r.src = at
	if dist > CHECK_NEAR + 0.1 * WS.M:
		close_in(r, to / maxf(dist, 1e-6), dist - CHECK_NEAR, dt)
		return r.left <= 0.0
	if r.check_hold <= 0.0:
		r.check_hold = CHECK_S
		w.react = &"no"
		w.react_t = 0.0
	r.check_hold -= dt
	if Vector2(to.x, to.z).length_squared() > 1e-10:
		w.yaw = lerp_angle(w.yaw, atan2(to.x, to.z), minf(1.0, dt * 6.0))
	w.vis_tilt = move_toward(w.vis_tilt, CHECK_LEAN, dt * 1.2)
	w.vis_v = 0.0
	w.gait = move_toward(w.gait, 0.0, dt * 4.0)
	return r.check_hold <= 0.0


## The first step of a scrap (reactions' _next_step calls this as a "fight" step starts): blows
## come in pairs from FIGHT_FIRST on; a bruiser leads with the cross and answers a blow the
## moment it lands (fight_tempers).
func begin(r) -> void:
	r.blow_t = -1.0
	r.pause = FIGHT_FIRST
	if FeatureFlags.enabled("fight_tempers") and r.temper == T_BRUISER:
		# A tough one leads with the cross and answers a blow the moment it lands.
		r.blow = 1
		r.pause = 0.0


## Fighting back: squares up to the hero, closes in to FIGHT_REACH and throws a punch whenever
## the pause is over. Over (true) once the punch under way is done and the hero cannot be fought,
## is FIGHT_LOST away or the step's time is up.
func step_fight(r, dt: float) -> bool:
	var w: WK.Walker = r.w
	r.left -= dt
	var me := w.pos + w.vis_off
	var to := Vector3(wk.player_pos.x - me.x, 0.0, wk.player_pos.z - me.z)
	var dist := to.length()
	if r.blow_t >= 0.0:
		punch(r, dt, dist)
		return false
	if not hero_open or dist > FIGHT_LOST or r.left <= 0.0:
		if hero_down and not r.stood_over and FeatureFlags.enabled("downed_awareness"):
			# A beat standing over the one they dropped (a last shout at them), then off.
			r.stood_over = true
			r.src = wk.player_pos
			r.steps.push_front(["place", &"shout", STAND_OVER_S])
		return true
	var dir := to / maxf(dist, 1e-6)
	w.yaw = lerp_angle(w.yaw, atan2(dir.x, dir.z), minf(1.0, dt * 10.0))
	r.pause -= dt
	if dist > FIGHT_REACH + FIGHT_SLACK:
		close_in(r, dir, dist - FIGHT_REACH, dt)
		return false
	w.react = &""
	if dancing(r):
		orbit(r, dist, dt)
	else:
		w.vis_v = 0.0
		w.gait = move_toward(w.gait, 0.0, dt * 4.0)
	if r.pause <= 0.0:
		r.blow_t = 0.0
		r.aimed = dist <= FIGHT_HIT
		w.react = FIGHT_BLOWS[r.blow][0]
		w.react_t = 0.0
		if r.aimed and FeatureFlags.enabled("counter_cues"):
			w.react_rate = WIND_RATE
		if on_wind_up.is_valid() and r.aimed:
			on_wind_up.call(w.id, fist(w), float(FIGHT_BLOWS[r.blow][1]))
	return false


## A dancer sidesteps while they wait for their punch (fight_tempers).
func dancing(r) -> bool:
	return FeatureFlags.enabled("fight_tempers") and r.temper == T_DANCER


## A dancer steps their own way round the hero on the ring of FIGHT_REACH (fight_tempers),
## facing them all the while: near enough to punch from, never still for the hero to line up.
func orbit(r, dist: float, dt: float) -> void:
	var w: WK.Walker = r.w
	var me := w.pos + w.vis_off
	var ring := clampf(dist, FIGHT_REACH * 0.75, FIGHT_REACH)
	var a := atan2(me.z - wk.player_pos.z, me.x - wk.player_pos.x) + float(r.strafe) * DANCE_W * dt
	var q := Vector3(wk.player_pos.x + cos(a) * ring, me.y, wk.player_pos.z + sin(a) * ring)
	var move := Vector3(q.x - me.x, 0.0, q.z - me.z)
	if collision != null:
		q = collision.move_body(me, move, BODY_R, BODY_H, WS.STEP_HEIGHT)
	set_feet(w, q)
	w.vis_v = DANCE_W * ring
	w.gait = move_toward(w.gait, 1.0, dt * 4.0)
	w.phase += move.length() / (0.75 * WS.M) * PI


## Runs at the hero from afar and walks the last metres (by at most room), stopped by walls and
## posts.
func close_in(r, dir: Vector3, room: float, dt: float) -> void:
	var w: WK.Walker = r.w
	var run := room > FIGHT_RUN
	var v: float = r.speed * (RUN_F if run else 1.0)
	var d := minf(v * dt, room)
	var p := w.pos + w.vis_off
	var q := p + dir * d
	if collision != null:
		q = collision.move_body(p, dir * d, BODY_R, BODY_H, WS.STEP_HEIGHT)
	set_feet(w, q)
	w.react = &"run" if run else &""
	w.vis_v = v
	w.gait = move_toward(w.gait, 1.0, dt * 4.0)
	w.phase += d / (0.75 * WS.M) * PI


## The punch under way: at its contact time it reaches a hero still within FIGHT_HIT in the cone
## ahead (reach_hero); once the clip has played, the next punch of the pair waits a pause.
func punch(r, dt: float, dist: float) -> void:
	var w: WK.Walker = r.w
	var spec: Array = FIGHT_BLOWS[r.blow]
	var t0: float = r.blow_t
	r.blow_t += dt
	w.react_t += dt
	w.vis_v = 0.0
	var fwd := Vector3(sin(w.yaw), 0.0, cos(w.yaw))
	var me := w.pos + w.vis_off
	var to := Vector3(wk.player_pos.x - me.x, 0.0, wk.player_pos.z - me.z)
	var contact := float(spec[1])
	# The wind-up reads: an announced punch holds its clip back through the first half of the run
	# to contact, then snaps in at the complementary speed (counter_cues). The two rates average
	# to one, so the clip lands with the blow's own clock and the counter window keeps its length.
	if r.aimed and FeatureFlags.enabled("counter_cues"):
		w.react_rate = (
			WIND_RATE if t0 < contact * 0.5 else (2.0 - WIND_RATE if t0 < contact else 1.0)
		)
	var reach := hero_open and dist <= FIGHT_HIT and to.dot(fwd) >= FIGHT_CONE * dist
	if t0 < contact and r.blow_t >= contact and reach:
		reach_hero(w, float(spec[2]))
	if r.blow_t >= float(spec[3]):
		r.blow_t = -1.0
		r.blow = (r.blow + 1) % FIGHT_BLOWS.size()
		r.pause = rng.randf_range(FIGHT_GAP.x, FIGHT_GAP.y)
		w.react = &""
		w.react_rate = 1.0


## w's punch of strength reaches the hero: countered (on_hero_parry), it misses; else it lands
## (on_hero_hit).
func reach_hero(w: WK.Walker, strength: float) -> void:
	var at := fist(w)
	if on_hero_parry.is_valid() and bool(on_hero_parry.call(w.id, at)):
		punches_parried += 1
		return
	punches_landed += 1
	if on_hero_hit.is_valid():
		on_hero_hit.call(at, strength, Vector3(sin(w.yaw), 0.0, cos(w.yaw)) * FIGHT_PUSH)


## Where w's fist lands: FIST ahead of and up from its drawn feet.
static func fist(w: WK.Walker) -> Vector3:
	var fwd := Vector3(sin(w.yaw), 0.0, cos(w.yaw))
	return w.pos + w.vis_off + fwd * (FIST.x * WS.M) + Vector3(0.0, FIST.y * WS.M, 0.0)


## Draws w's feet at q, on the ground there (off the curb into the road, say).
func set_feet(w: WK.Walker, q: Vector3) -> void:
	var y := w.pos.y + w.vis_off.y
	if collision != null:
		var g := collision.walk_height(q)
		if not is_nan(g):
			y = g
	w.vis_off = Vector3(q.x - w.pos.x, y - w.pos.y, q.z - w.pos.z)
