extends RefCounted
## The police answering the hero's offence (the police_response flag; docs/fp/ARCHITECTURE.md, E
## Traffic & pedestrians). A car incidents.gd called (a carjack, a knock-down, the third punch:
## fleets.gd keeps its reason) that reaches the scene posts "Police arrived on <street>", and when
## the hero is within ENGAGE_R of it two officers get out (walkers of the roster's police bodies,
## role ROLE, driven here: reactions.gd leaves them out of every scene), stand by the car on the
## curb side and look for the hero. A hero on foot within APPROACH_R gets one of them walking up; at
## WARN_R the officer shouts "Stop right there!" and goes on until HOLD_R. A hero within ARREST_R of
## an officer for ARREST_S (or in a car stopped beside the police car that long), once they have
## been shouted at and the shout is over (WARN_S: it comes first, whoever is near), is busted
## (police_bust.gd: a fine by what they did, the fade, out of the car and outside the nearest
## station), the officers go back to the car and the crew leaves early. A hero who gets further than
## FLEE_R, or drives off, has the officers back in the car and the car after them: it drives to the
## hero's road tile again every REPATH_S for PURSUE_S ("Police are after you", said once it is up to
## speed: the first leg is often a slow U-turn), siren on. It gives up with "Police lost you" ("gave
## up the chase" within NEAR_R of the hero). It has caught up with a hero who has slowed down (or is
## stopped and near them, or has stood STUCK_S in the traffic, or has come as near as the roads go
## to a hero off them) when it stops where it is, never braked to a halt across a U-turn arc or a
## junction, and its officers get out again from up to FLEE_R. Against a hero who has stopped it
## keeps on up to PURSUE_MAX while it is still closing on them, and while it is within NEAR_R of
## one, however they move, so a hero who runs about near the scene is not given up on at 30 s. A
## hero beyond ENGAGE_R but within LOSE_R when the car arrives is hunted at once; beyond LOSE_R it
## is "No sign of the suspect". The officers keep the stay up while they are after the hero for at
## most BUSY_MAX seconds. Every move of the car goes through fleets.gd (recall, redirect: its lanes,
## its speed), so nothing is placed and nothing blocks the hero. The officers and the arrest run on
## real seconds (the hero is real-time: 4x or 8x leaves them the same time to act; the hero's pace
## is the path over PACE_S real seconds, whatever the frame structure), the car on the sim's. Flag
## off: none of this runs and a called car is as it was (it sits at the scene with its siren for its
## stay).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const BUST := preload("res://scripts/fp/traffic/police_bust.gd")

## An officer's walker role; walker ids of officers count up from FIRST_ID (clear of the street's
## own and of occupants.gd's PROXY_ID).
const ROLE := "officer"
const FIRST_ID := 1 << 25
const OFFICERS := 2
## What the hero did, in dollars of fine (incidents.gd's causes; "officer" is a blow at one).
const FINES := {"carjack": 500, "punch": 200, "officer": 300}
const DEFAULT_FINE := 200
## Officers come out when the hero is this close to the car; a hero this far is running away.
const ENGAGE_R := 50.0 * WS.M
const FLEE_R := 60.0 * WS.M
## One officer walks up to a hero on foot within APPROACH_R of the car (and gives up past 1.5 times
## that), shouts at WARN_R and closes to HOLD_R; one who has stood at the hero HELD_S without an
## arrest (they are out of reach: on a roof) gives up too.
const APPROACH_R := 30.0 * WS.M
const WARN_R := 12.0 * WS.M
const HOLD_R := 2.0 * WS.M
const HELD_S := 4.0
## A walk is over when within ARRIVE_EPS of its stop radius: float32 positions cannot close the last
## hair (the step falls below the spacing of the coordinates), so an exact stop is never reached.
const ARRIVE_EPS := 0.02 * WS.M
## The hero's pace is the path they covered over PACE_S real seconds (hops of more than HOP_MAX in
## one step are a teleport, not a stride).
const PACE_S := 0.25
const HOP_MAX := 15.0 * WS.M
## The hero is held when within ARREST_R of an officer (feet within ARREST_UP of theirs), or in a
## car stopped (CAR_STOPPED, u/s) within CAR_ARREST_R of the police car, for ARREST_S seconds
## (the count falls back at the same rate while they are clear).
const ARREST_R := 3.0 * WS.M
const ARREST_UP := 2.0 * WS.M
const CAR_ARREST_R := 8.0 * WS.M
const CAR_STOPPED := 1.0 * WS.M
const ARREST_S := 2.0
## A car under way at more than DRIVE_OFF_V (u/s) beyond DRIVE_OFF_R of the police car has driven
## off.
const DRIVE_OFF_R := 25.0 * WS.M
const DRIVE_OFF_V := 3.0 * WS.M
## Officers' pace out, up to the hero and back to the car when the hero is running.
const WALK := 2.0 * WS.M
const RUN := 4.0 * WS.M
## Seconds the warning shout takes, an officer who stalls (a wall in the way) this long gives up
## for GIVE_UP_S, and the officers have RECALL_S to get back in the car.
const WARN_S := 1.5
const STALL_S := 2.5
const GIVE_UP_S := 15.0
const RECALL_S := 8.0
## The stay left (s) at which the officers go back to the car to leave with it, and how much of it
## the car keeps while they are busy with the hero.
const WRAP_S := 8.0
## The officers keep the stay up while they are after the hero for at most BUSY_MAX real seconds in
## all (a hero running rings round the car is not chased for ever).
const BUSY_MAX := 45.0
## The chase: PURSUE_S seconds at most against a hero who keeps moving (PURSUE_MAX against one who
## has stopped, while the car closed on them by PROGRESS_M over the last PROGRESS_S: the first leg
## of a chase is often a slow U-turn), the road tile of the hero asked for again every REPATH_S,
## given up at once beyond LOSE_R, at most MAX_CHASES times in a response. Close (CATCH_R) to a
## hero walking pace or slower (CATCH_HERO, u/s) the car, at CATCH_CAR u/s or less, brakes where
## it is (CATCH_BRAKE, u/s^2) and once stopped (STOPPED_V, u/s) its officers get out again for
## CATCH_STAY seconds.
const PURSUE_S := 30.0
const PURSUE_MAX := 60.0
## A car within NEAR_R of the hero keeps after them to PURSUE_MAX; one given up on within it
## "gave up the chase", beyond it "lost" them. "Police are after you" is said once the car is up to
## TOLD_V (u/s) or TOLD_S seconds into the chase (the first leg is often a slow U-turn).
const NEAR_R := 40.0 * WS.M
const TOLD_V := 5.0 * WS.M
const TOLD_S := 12.0
const PROGRESS_S := 10.0
const PROGRESS_M := 5.0 * WS.M
const REPATH_S := 1.5
const LOSE_R := 500.0 * WS.M
const MAX_CHASES := 2
const CATCH_R := 20.0 * WS.M
const CATCH_HERO := 2.5 * WS.M
const CATCH_CAR := 3.0 * WS.M
const CATCH_BRAKE := 3.0 * WS.M
const STOPPED_V := 0.5 * WS.M
const CATCH_STAY := 25.0
## A car that has stood STUCK_S seconds in a chase (held by the lights or the traffic, or by the
## hero) with the hero within the flee radius is as near as it gets: caught, whatever their pace.
const STUCK_S := 5.0
## Officers get out this far beside the car's flank (its door), and stand this far (the curb).
const DOOR_OUT := 0.45 * WS.M
const POST_OUT := 1.6 * WS.M
## No second arrest within this many seconds of one.
const BUST_COOL := 20.0


## One officer on foot: k 0 the front door, 1 the rear; mode "out" (to their post), "post",
## "approach", "warn" (the shout), "back" (to the car) or "in" (gone into it).
class Officer:
	extends RefCounted
	var w: WK.Walker
	var k: int = 0
	var mode: String = "out"
	var t: float = 0.0
	var stall: float = 0.0
	var held: float = 0.0
	var until: float = 0.0


## The response of one police car; phase "scene", "recall" (officers back to the car, then after:
## "leave" or "chase") or "chase".
class Resp:
	extends RefCounted
	var c: VH.Car
	var phase: String = "scene"
	var after: String = ""
	var officers: Array = []
	var deployed: bool = false
	var side: float = -1.0
	var fine: int = 0
	var why: String = ""
	var street: String = ""
	var arrest_t: float = 0.0
	var busy_t: float = 0.0
	var still: float = 0.0
	var told: bool = false
	var warned: bool = false
	var warn_t: float = 0.0
	var t: float = 0.0
	var mark_t: float = 0.0
	var mark_d: float = 0.0
	var closing: bool = false
	var chases: int = 0
	var repath: float = 0.0
	var goal: int = -1


var f: Object
## The arrest and what follows it.
var bust: BUST
var _resp: Dictionary = {}
## Cause -> traffic clock of the hero's latest such offence (a car called earlier still gets the
## worse fine).
var _offences: Dictionary = {}
var _next_id: int = FIRST_ID
## Real seconds the responses have run (for the officers' give-up and the arrest cool-down).
var _rt: float = 0.0
var _last_bust: float = -INF
var _hero_was := Vector3(INF, INF, INF)
var _hero_v: float = 0.0
var _pace_t: float = 0.0
var _pace_d: float = 0.0


func setup(p_f: Object) -> void:
	reset()
	f = p_f
	_offences.clear()
	_rt = 0.0
	_last_bust = -INF
	_forget_pace()
	bust = BUST.new()
	bust.setup(f)


## Everything gone (a world rebuild, teardown): officers freed, responses forgotten, an arrest's
## fade dropped and the hero given their input back.
func reset() -> void:
	clear()
	if bust != null:
		bust.clear()


## Frees every officer and forgets every response; with recall, a car mid-response goes home
## (the flag went off) instead of waiting on a response that is gone.
func clear(recall: bool = false) -> void:
	for r: Resp in _resp.values():
		_free_officers(r)
		if recall and r.phase != "scene" and not r.c.dead:
			f.fleets.recall(r.c)
	_resp.clear()


func on() -> bool:
	return FeatureFlags.enabled("police_response")


## The walkers out beside police car id (a test hook).
func officers_of(id: int) -> Array:
	var out: Array = []
	var r: Resp = _resp.get(id)
	if r != null:
		for off: Officer in r.officers:
			out.append(off.w)
	return out


## Police car id's phase ("scene", "recall", "chase"), "" when it is not being run (a test hook).
func phase_of(id: int) -> String:
	var r: Resp = _resp.get(id)
	return r.phase if r != null else ""


## The hero did cause (incidents.gd): a response under way, or one still on its way, fines for it.
func note_offence(cause: String) -> void:
	if not on() or not FINES.has(cause):
		return
	_offences[cause] = f.clock
	for r: Resp in _resp.values():
		_raise(r, cause)


## The hero struck officer w: that is resisting, and the arrest is at once.
func struck(w: WK.Walker) -> void:
	for r: Resp in _resp.values():
		for off: Officer in r.officers:
			if off.w == w:
				_raise(r, "officer")
				_bust(r)
				return


## Police car c (a crew called for the hero's offence) is at the scene: tell the player, and
## put the officers out or send it after a hero who is not there.
func on_arrived(c: VH.Car) -> void:
	if not on() or _resp.has(c.id):
		return
	var o: Dictionary = c.owner
	var r := Resp.new()
	r.c = c
	r.why = str(o.get("why", ""))
	r.fine = int(FINES.get(r.why, DEFAULT_FINE))
	# What the hero did since the car set off (a second of slack for the step it was made in).
	var since: float = f.clock - float(o.get("t", 0.0)) - 1.0
	for cause: String in _offences:
		if float(_offences[cause]) >= since:
			_raise(r, cause)
	r.street = f.street_label(_tile(c.pos))
	_resp[c.id] = r
	var where := (" on " + r.street) if not r.street.is_empty() else ""
	_toast("Police arrived" + where, "alert")
	var d := _flat(_hero(), c.pos)
	if d <= ENGAGE_R:
		_deploy(r)
	elif d <= LOSE_R:
		_begin_chase(r)
	else:
		_toast("No sign of the suspect", "info")


func step(dt: float) -> void:
	# Real seconds (dt is the sim's, scaled by the time speed): the hero's own pace and the
	# officers' clocks keep to these; the clock runs between responses too (the arrest cool-down).
	# A warm-up after a teleport (the feature's _refill) runs the street for seconds in one frame:
	# the responses' clocks are not for that.
	if f.warming:
		return
	var rd := _real(dt)
	_rt += rd
	if _resp.is_empty():
		_forget_pace()
		return
	if not on():
		clear(true)
		return
	_track_hero(_hero(), rd)
	for id: int in _resp.keys():
		# One response's arrest can end another's: it may be gone by its turn.
		var r: Resp = _resp.get(id)
		if r != null:
			_step_resp(r, dt)


## The hero's pace from the path they cover over PACE_S real seconds: they move once per drawn
## frame while the street steps two to twelve times in it, so a pace taken step by step is all
## spikes at 4x and 8x.
func _track_hero(p: Vector3, rd: float) -> void:
	if _hero_was.is_finite():
		var hop := _flat(p, _hero_was)
		if hop <= HOP_MAX:
			_pace_d += hop
	_hero_was = p
	_pace_t += rd
	if _pace_t >= PACE_S:
		_hero_v = _pace_d / _pace_t
		_pace_t = 0.0
		_pace_d = 0.0


func _forget_pace() -> void:
	_hero_was = Vector3(INF, INF, INF)
	_hero_v = 0.0
	_pace_t = 0.0
	_pace_d = 0.0


func _step_resp(r: Resp, dt: float) -> void:
	var c := r.c
	if c.dead or not (c.owner is Dictionary):
		_end(r)
		return
	var o: Dictionary = c.owner
	if str(o.get("phase", "")) == "leaving":
		_end(r)
		return
	var rd := _real(dt)
	r.warn_t = maxf(r.warn_t - rd, 0.0)
	match r.phase:
		"scene":
			_scene(r, o, rd)
		"recall":
			r.t += rd
			_recall_step(r, o)
		"chase":
			r.t += dt
			_chase(r, dt)
	for off: Officer in r.officers.duplicate():
		_officer(r, off, rd)


# ------------------------------------------------------------------ the scene


func _scene(r: Resp, o: Dictionary, dt: float) -> void:
	var hero := _hero()
	var d := _flat(hero, r.c.pos)
	if not r.deployed:
		# Not with the stay about to run out: they would be out for a frame and called back.
		if d <= _reach(r, ENGAGE_R) and r.c.v <= STOPPED_V and float(o["stay"]) > WRAP_S:
			_deploy(r)
		return
	var busy := false
	for off: Officer in r.officers:
		busy = busy or off.mode == "approach" or off.mode == "warn"
	if busy:
		r.busy_t += dt
	if busy and r.busy_t < BUSY_MAX:
		o["stay"] = maxf(float(o["stay"]), WRAP_S + 2.0)
	elif float(o["stay"]) <= WRAP_S:
		_recall(r, "leave")
		return
	var drv := _driven()
	if d > FLEE_R or (drv != null and drv.v > DRIVE_OFF_V and d > DRIVE_OFF_R):
		_recall(r, "chase")
		return
	_send_up(r, hero, d, drv)
	_arrest(r, hero, d, drv, dt)


## Sends one officer up to a hero on foot near the car, and calls an officer off one who is out of
## reach.
func _send_up(r: Resp, hero: Vector3, d: float, drv: VH.Car) -> void:
	var on_foot: bool = drv == null and not f.hero_aboard
	var reach := _reach(r, APPROACH_R)
	var up: Officer = null
	for off: Officer in r.officers:
		if off.mode == "approach" or off.mode == "warn":
			up = off
	if up != null:
		if d > reach * 1.5 or (drv != null and drv.v > CAR_STOPPED):
			# The hero is leaving: the officer comes back, and warns them again if they return.
			up.mode = "out"
			r.warned = false
		return
	if not on_foot or d > reach:
		return
	var best := INF
	for off: Officer in r.officers:
		var od := _flat(hero, off.w.pos)
		if off.mode == "post" and off.until <= _rt and od < best:
			best = od
			up = off
	if up != null:
		up.mode = "approach"
		up.stall = 0.0


## The arrest: the hero close to an officer, or in a stopped car close to the police car, long
## enough (ARREST_S) after the warning: whoever is nearest shouts first when nobody has, and the
## count starts once the shout is over.
func _arrest(r: Resp, hero: Vector3, d: float, drv: VH.Car, dt: float) -> void:
	var stopped: bool = drv == null and not f.hero_aboard
	stopped = stopped or (drv != null and drv.v <= CAR_STOPPED)
	var near := false
	var by: Officer = null
	if stopped and not _downed():
		var best := INF
		for off: Officer in r.officers:
			var od := _flat(hero, off.w.pos)
			if off.mode != "back" and od < best:
				best = od
				by = off
			if off.mode != "back" and od <= ARREST_R:
				near = near or absf(hero.y - off.w.pos.y) <= ARREST_UP
		near = near or (drv != null and d <= CAR_ARREST_R)
	if near and not r.warned:
		_shout(r, by)
	var held := near and r.warned and r.warn_t <= 0.0
	r.arrest_t = r.arrest_t + dt if held else maxf(r.arrest_t - dt, 0.0)
	if r.arrest_t >= ARREST_S:
		_bust(r)


func _bust(r: Resp) -> void:
	if _rt - _last_bust < BUST_COOL:
		return
	_last_bust = _rt
	var hero := _hero()
	for other: Resp in _resp.values():
		_recall(other, "leave")
	_recall_en_route()
	bust.begin(maxi(r.fine, 1), r.why, hero, r.street)


## Police cars still on their way to the scene turn back: the hero they were called for is taken.
func _recall_en_route() -> void:
	for c: VH.Car in f.vehicles.cars:
		if c.role != "crew" or c.dead or not (c.owner is Dictionary):
			continue
		var o: Dictionary = c.owner
		if str(o.get("kind", "")) == "police" and o.has("stay"):
			if str(o.get("phase", "")) == "to_scene":
				f.fleets.recall(c)


func _raise(r: Resp, cause: String) -> void:
	if int(FINES[cause]) > r.fine:
		r.fine = int(FINES[cause])
		r.why = cause


# ------------------------------------------------------------------ recall, chase


## The officers go back to the car, then it leaves (or sets off after the hero).
func _recall(r: Resp, after: String) -> void:
	if r.phase == "recall" and (r.after == after or after == "chase"):
		return
	if r.phase == "chase":
		after = "leave"
	r.phase = "recall"
	r.after = after
	r.t = 0.0
	for off: Officer in r.officers:
		off.mode = "back"
		off.stall = 0.0
	if r.officers.is_empty():
		_recalled(r)


func _recall_step(r: Resp, o: Dictionary) -> void:
	o["stay"] = maxf(float(o["stay"]), 1.0)
	if r.t >= RECALL_S or r.officers.is_empty():
		_recalled(r)


func _recalled(r: Resp) -> void:
	_free_officers(r)
	if r.after == "leave":
		f.fleets.recall(r.c)
		_resp.erase(r.c.id)
	else:
		_begin_chase(r)


func _begin_chase(r: Resp) -> void:
	if r.chases >= MAX_CHASES:
		_lose(r)
		return
	r.chases += 1
	r.phase = "chase"
	r.t = 0.0
	r.repath = 0.0
	r.goal = -1
	r.mark_t = 0.0
	r.mark_d = _flat(_hero(), r.c.pos)
	r.closing = false
	r.still = 0.0
	r.told = r.chases > 1
	(r.c.owner as Dictionary)["phase"] = "chase"
	r.c.state = "pursuing"


func _chase(r: Resp, dt: float) -> void:
	var c := r.c
	var hero := _hero()
	var d := _flat(hero, c.pos)
	var drv := _driven()
	var slow := _hero_v <= CATCH_HERO and (drv == null or drv.v <= CATCH_HERO)
	# Has the car closed on the hero over the last PROGRESS_S?
	r.mark_t += dt
	if r.mark_t >= PROGRESS_S:
		r.mark_t = 0.0
		r.closing = d < r.mark_d - PROGRESS_M
		r.mark_d = d
	var limit := PURSUE_MAX if (slow and r.closing) or d <= NEAR_R else PURSUE_S
	r.still = r.still + dt if c.v <= STOPPED_V else 0.0
	if _is_caught(r, d, slow):
		_caught(r)
	elif r.t >= limit or d > LOSE_R:
		_lose(r, d)
	else:
		if not r.told and (c.v >= TOLD_V or r.t >= TOLD_S):
			r.told = true
			_toast("Police are after you", "alert")
		r.repath -= dt
		if r.repath <= 0.0:
			_repath(r, hero)


## Whether the car has caught up with the hero. One that has come as near as the roads go to a hero
## off them (it has arrived) takes them for caught from as far as the flee radius, and so does one
## that has stood STUCK_S where it is; one under way, from CATCH_R, at CATCH_CAR u/s or less, with a
## hero who has slowed down, or a car already stopped near one who runs about; and not braked to a
## stop on a U-turn arc or a junction movement. Never against a hero in a car.
func _is_caught(r: Resp, d: float, slow: bool) -> bool:
	var c := r.c
	if f.hero_aboard:
		return false
	if r.still >= STUCK_S and d <= FLEE_R:
		return true
	var reach := FLEE_R if c.arrived else CATCH_R
	if d > reach or c.v > CATCH_CAR or not (slow or c.v <= STOPPED_V):
		return false
	return c.v <= STOPPED_V or not _on_turn(c)


func _repath(r: Resp, hero: Vector3) -> void:
	r.repath = REPATH_S
	var i := _road_tile(hero)
	if i < 0 or (i == r.goal and not r.c.arrived):
		return
	if f.fleets.redirect(r.c, i, "pursuing"):
		r.goal = i
	else:
		r.repath = 0.2


## The car caught up with a hero who has slowed down: it brakes where it is (its goal a braking
## distance on, along its lane) and the officers get out again once it has stopped.
func _caught(r: Resp) -> void:
	var c := r.c
	var o: Dictionary = c.owner
	o["phase"] = "at_scene"
	o["stay"] = CATCH_STAY
	# A fresh call clock: fleets.gd sends a call home CALL_MAX seconds after it was dispatched,
	# which a long drive and a chase can have used up.
	o["t"] = 0.0
	c.state = "at the scene"
	c.path.clear()
	c.goal_lane = c.lane
	c.goal_s = minf(c.s + c.v * c.v / (2.0 * CATCH_BRAKE), c.lane.length)
	c.arrived = false
	r.phase = "scene"
	r.t = 0.0
	r.arrest_t = 0.0
	r.busy_t = 0.0
	r.warned = false
	r.deployed = false


## How far from the car its officers get out for, and walk up to, the hero: `plain` in a response as
## it began, as far as the flee radius in one that came to them in a chase (the car could get no
## nearer than the road: a hero in a park is 10 to 20 m further off than the road tile it went to).
func _reach(r: Resp, plain: float) -> float:
	return FLEE_R if r.chases > 0 else plain


## True on a junction movement or a U-turn arc: a car braked to a stop there would stand across the
## carriageway (a bend of the road is a lane it can stop in; one already stopped there, held by the
## lights or the traffic, is stopped).
func _on_turn(c: VH.Car) -> bool:
	return c.lane != null and (c.lane.kind == LG.MOVE or c.lane.kind == LG.UTURN)


func _lose(r: Resp, d: float = INF) -> void:
	_toast("Police gave up the chase" if d <= NEAR_R else "Police lost you", "info")
	f.fleets.recall(r.c)
	_end(r)


func _end(r: Resp) -> void:
	_free_officers(r)
	_resp.erase(r.c.id)


# ------------------------------------------------------------------ officers


## The officers get out beside the car, on the curb side, and walk to their posts.
func _deploy(r: Resp) -> void:
	r.deployed = true
	r.side = _curb_side(r.c)
	_free_officers(r)
	var seed: int = hash(Vector2i(f.ctx.sim.city_seed, r.c.id))
	for k in range(OFFICERS):
		var off := Officer.new()
		off.k = k
		var w := WK.Walker.new()
		w.id = _next_id
		_next_id += 1
		w.role = ROLE
		w.speed = WALK
		f.people.dress(w, null, "police", absi(seed) + k)
		if w.av < 0:
			w.model = f.ambient.person_model.call(absi(seed) + k)
		w.pos = _spot(r, k, DOOR_OUT)
		w.yaw = r.c.yaw + r.c.vis_yaw + r.side * 0.5 * PI
		w.state = "stand"
		w.idle_clip = &"idle"
		f.walkers.walkers.append(w)
		off.w = w
		r.officers.append(off)


func _free_officers(r: Resp) -> void:
	for off: Officer in r.officers:
		if not off.w.dead:
			f.walkers.remove(off.w)
	r.officers.clear()


## One step of officer off: where its mode takes it.
func _officer(r: Resp, off: Officer, dt: float) -> void:
	var hero := _hero()
	var w := off.w
	if w.dead:
		r.officers.erase(off)
		return
	match off.mode:
		"out":
			if _walk_to(off, _spot(r, off.k, POST_OUT), WALK, dt, 0.15 * WS.M):
				off.mode = "post"
		"post":
			_look(off, hero, dt)
		"approach":
			_approach(r, off, hero, dt)
		"warn":
			_face(w, hero, dt)
			off.t -= dt
			if off.t <= 0.0:
				w.react = &""
				off.mode = "approach"
		"back":
			var run := _flat(hero, r.c.pos) > ENGAGE_R * 0.5
			var pace := RUN if run else WALK
			var there := _walk_to(off, _spot(r, off.k, DOOR_OUT), pace, dt, 0.3 * WS.M)
			if there or off.stall > STALL_S:
				f.walkers.remove(w)
				r.officers.erase(off)
				return
	if off.mode == "approach" and off.stall > STALL_S:
		off.mode = "out"
		off.until = _rt + GIVE_UP_S
		off.stall = 0.0


func _approach(r: Resp, off: Officer, hero: Vector3, dt: float) -> void:
	var w := off.w
	var d := _flat(hero, w.pos)
	if d <= WARN_R and not r.warned:
		_shout(r, off)
		return
	if not _walk_to(off, hero, WALK, dt, HOLD_R):
		off.held = 0.0
		return
	_face(w, hero, dt)
	# At the hero and no arrest (they are out of reach): leave them be for a while.
	off.held += dt
	if off.held > HELD_S:
		off.held = 0.0
		off.mode = "out"
		off.until = _rt + GIVE_UP_S


## Officer off (null: nobody to show it) shouts "Stop right there!" at the hero: the warning the
## arrest waits on (WARN_S).
func _shout(r: Resp, off: Officer) -> void:
	r.warned = true
	r.warn_t = WARN_S
	_toast("Stop right there!", "alert")
	if off == null:
		return
	off.mode = "warn"
	off.t = WARN_S
	off.held = 0.0
	_stand(off.w)
	off.w.react = &"shout"


## An officer at their post turns to the hero while they are near, else looks about.
func _look(off: Officer, hero: Vector3, dt: float) -> void:
	var w := off.w
	_stand(w)
	if _flat(hero, w.pos) <= FLEE_R:
		_face(w, hero, dt)
		w.idle_clip = &"idle_look"
	else:
		w.idle_clip = &"idle"


## Walks off toward `to` at pace u/s until within stop of it (kept off walls and posts, a walk
## that makes no headway counts up off.stall). True when there.
func _walk_to(off: Officer, to: Vector3, pace: float, dt: float, stop: float) -> bool:
	var w := off.w
	var dx := to.x - w.pos.x
	var dz := to.z - w.pos.z
	var dist := sqrt(dx * dx + dz * dz)
	if dist <= stop + ARRIVE_EPS:
		_stand(w)
		off.stall = 0.0
		return true
	var step := minf(pace * dt, dist - stop)
	var dir := Vector3(dx, 0.0, dz) / dist
	var from := w.pos
	var np := from + dir * step
	var col: Variant = f.ctx.collision
	if col != null:
		var h := WS.PLAYER_HEIGHT
		np = col.move_body(from, dir * step, WS.PLAYER_RADIUS, h, WS.STEP_HEIGHT)
		var y: float = col.walk_height(np)
		np.y = y if not is_nan(y) else from.y
	else:
		np.y = from.y
	var made := Vector2(np.x - from.x, np.z - from.z).length()
	off.stall = off.stall + dt if made < step * 0.3 else 0.0
	w.pos = np
	w.yaw = lerp_angle(w.yaw, atan2(dir.x, dir.z), minf(1.0, dt * 8.0))
	w.v = pace
	w.vel = Vector3.ZERO
	w.state = "walk"
	w.react = &"run" if pace > WALK * 1.5 else &""
	return false


func _stand(w: WK.Walker) -> void:
	w.v = 0.0
	w.vel = Vector3.ZERO
	w.state = "stand"
	if w.react == &"run":
		w.react = &""


func _face(w: WK.Walker, at: Vector3, dt: float) -> void:
	var dx := at.x - w.pos.x
	var dz := at.z - w.pos.z
	if dx * dx + dz * dz > 1e-8:
		w.yaw = lerp_angle(w.yaw, atan2(dx, dz), minf(1.0, dt * 6.0))


# ------------------------------------------------------------------ the world


## The point beside car c's flank on side r.side, `out` from it, level with officer k's door.
func _spot(r: Resp, k: int, out: float) -> Vector3:
	var c := r.c
	var xf := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off)
	var p := xf * Vector3(r.side * (c.half_w + out), 0.0, c.length * (0.22 if k == 0 else -0.18))
	var col: Variant = f.ctx.collision
	var y: float = col.walk_height(p) if col != null else NAN
	p.y = y if not is_nan(y) else WS.SIDEWALK_TOP
	return p


## The side of car c (+1 the driver's, -1 the other, by its own x axis) the nearest sidewalk is
## on: where the officers get out; the right-hand side without a sidewalk to go by.
func _curb_side(c: VH.Car) -> float:
	var tile := _tile(c.pos)
	var near: Array = f.peds.nearest_on_tile(Vector2(c.pos.x, c.pos.z), tile) if tile >= 0 else []
	if near.is_empty():
		return -1.0
	var sp: Vector3 = f.peds.pos_at(near[0], near[1])
	var yaw: float = c.yaw + c.vis_yaw
	var left := Vector2(cos(yaw), -sin(yaw))
	return 1.0 if Vector2(sp.x - c.pos.x, sp.z - c.pos.z).dot(left) > 0.0 else -1.0


## The road tile nearest p within LOSE_R (where the hero gets nearest to by road), -1 when none.
## It looks ring by ring (Chebyshev) round p's tile and stops once the next ring is further than the
## best found (p is at most half a tile off its tile's centre): a few rings, not every road tile
## of the city, whenever the hero is stood still or on the move.
func _road_tile(p: Vector3) -> int:
	var tiles: Dictionary = f.lanes.tiles
	var cx := roundi(p.x)
	var cy := roundi(p.z)
	var max_ring := ceili(LOSE_R) + 1
	var best := -1
	var best_d := LOSE_R
	var ring := 0
	while ring <= max_ring and float(ring) - 0.5 < best_d:
		for dy in range(-ring, ring + 1):
			var edge := absi(dy) == ring
			for dx in range(-ring, ring + 1, 1 if edge else maxi(2 * ring, 1)):
				var x := cx + dx
				var y := cy + dy
				if not D.in_bounds(x, y):
					continue
				var i := D.idx(x, y)
				if not tiles.has(i):
					continue
				var d := Vector2(x - p.x, y - p.z).length()
				if d < best_d:
					best_d = d
					best = i
		ring += 1
	return best


func _hero() -> Vector3:
	return f.ctx.player_position()


## The car the hero drives, null on foot.
func _driven() -> VH.Car:
	var d: VH.Car = f._driven
	return d if d != null and not d.dead else null


## True while the hero is knocked down or out (nobody is arrested lying there).
func _downed() -> bool:
	var health: Object = f.ctx.feature("health")
	return health != null and bool(health.call("downed"))


func _toast(text: String, kind: String) -> void:
	if f.ctx.bus != null:
		f.ctx.bus.toast.emit(text, kind)


## dt sim seconds as real ones (the hero's, the HUD's): divided by the time speed.
func _real(dt: float) -> float:
	return dt / maxf(float(f.ctx.sim.speed), 1.0)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func _tile(p: Vector3) -> int:
	var x := roundi(p.x)
	var y := roundi(p.z)
	return D.idx(x, y) if D.in_bounds(x, y) else -1
