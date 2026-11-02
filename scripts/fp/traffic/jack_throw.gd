extends RefCounted
## How the driver the hero pulls out of a car goes, from the seat to the ground (the carjack_throw
## flag, which needs hit_feel: on(); docs/fp/ARCHITECTURE.md, Integration: driving), as one sequence
## on the clips the walkers already have. reactions.gd starts it (_plan_down for the blow, drag_out
## for the haul) and runs its two hooks (haul, fly); this file holds the curves, each a pure
## function of time so a test can sample them.
## The haul (HAUL_S, in the sit pose): the body is jerked toward the door, then hauled out over
## the sill, speeding up, leaning out head first about the hips so the legs trail in the car
## (HEAD_OUT rad at the release) and turning to face the car (never faster than TURN_RATE: a turn
## too big for that in the haul, a moving car's, takes longer and runs on into the flight), ending
## at the speed the flight carries on at (a short fling's is slower than the haul's own pace: the
## pull then peaks and eases off into the flight). Where the door asks (carjack.gd, jack_landing.gd)
## it is let go a little further down the car's side than straight out of the seat: it goes straight
## out over the sill first and drifts there over the last of the haul. The flight: the blow's
## strength sets how high (APEX_K metres per metre of the fling) and how long it is in the air, and
## how far it twists (SPIN rad, away from the open door panel or, with none, one way or the other by
## who they are, at most so far that the turning is never faster than SPIN_RATE, the turn still
## running on included); the lean eases out as the knockback clip, played slowed through the air so
## its own fall meets the ground at touchdown (0 to T_CONTACT, within a frame), flips the body back;
## the ground takes the rest as a skid, and the touchdown is told (on_landed) as it happens. A car
## that is moving carries the body on at its own pace through the haul (the seat moves with it; it
## eases down to the flight's over the last CARRY_EASE_S) and at up to CARRY_MAX of it through the
## flight (the car drives on from under it at the release), where it would otherwise be left
## hanging behind it.
## With no plan the haul is the plain one, the sit pose tipped back (PLAIN_S).

const WS := preload("res://scripts/fp/world_scale.gd")
const G := 9.8
## The haul: seconds, the hips' lift over the sill, the lean toward the door at the release (rad)
## and the share of the haul over which the body turns to face the car.
const HAUL_S := 0.45
const LIFT := 0.2 * WS.M
const HEAD_OUT := 0.62
const TURN := Vector2(0.15, 0.9)
## Where the body is let go further down the car's side than straight out of the seat (carjack.gd,
## to clear the open door), it goes straight out over the sill first and drifts there only after
## the share SHIFT_AT of the way across.
const SHIFT_AT := 0.55
## The flight's apex per metre of the fling, from the weakest to the hardest blow, and the twist
## (rad) likewise. The skid takes SKID_M metres of the fling over SKID_S seconds, at most half.
const APEX_K := Vector2(0.1, 0.19)
const SPIN := Vector2(0.4, 1.3)
## The fastest the body turns (rad/s, at the middle of the flight): a short fling is a short hop and
## twists less, the angle scaled to the air time, not turned in a blink.
const SPIN_RATE := 8.0
## The fastest the turn to face the car goes (rad/s, at the middle of its smoothstep): the same
## as the twist's. A turn too big for that in the haul's own TURN window (a moving car's
## carries the release facing round 155 degrees) takes longer, on into the flight.
const TURN_RATE := SPIN_RATE
const RATE_SAMPLES := 100
const SKID_M := 0.6
const SKID_S := 0.45
## The knockback clip's seconds when its back is on the ground (it starts at 0: a mixer starts a new
## clip from its beginning, people.gd) and the pace of a moving car the flight keeps (m/s, at most).
const T_CONTACT := 0.3
const CARRY_MAX := 5.0 * WS.M
## A moving car carries the haul at its whole pace; over the last CARRY_EASE_S of it that eases down
## (smoothly) to the pace the flight keeps, so the body is not stopped dead from one frame to the
## next as the car drives on from under it at the release.
const CARRY_EASE_S := 0.2
## The plain haul (no plan, reactions.gd drag_out): seconds, the hips' lift over the sill and the
## tip back (rad) at its middle.
const PLAIN_S := 0.5
const PLAIN_LIFT := 0.2 * WS.M
const PLAIN_TILT := 0.5


## One throw's numbers: made when the blow is planned, read as the haul and the flight run.
class Plan:
	extends RefCounted
	var fling: float = 0.0  # metres the blow throws, as asked
	var door := Vector3.ZERO  # level unit: out of the car, the way the blow goes
	var apex: float = 0.0  # metres, the top of the arc above where it leaves
	var air: float = 0.0  # seconds in the air
	var skid: float = 0.0  # the share of the slide skidded along the ground
	var spin: float = 0.0  # the twist at mid-flight (rad, signed)
	var rate: float = 1.0  # the pace the fall clip plays at through the air
	var yaw_f: float = 0.0  # facing at the release: toward the car, the flight's tail first
	var yaw_0: float = 0.0  # facing in the seat, with a haul
	var turn_t: Vector2 = Vector2(0.0, 0.0)  # seconds from the blow the turn starts and takes
	var seated: bool = false  # drawn at the wheel, so hauled out first (the walker's seated)
	var haul: bool = false  # hauled out of a seat first (drag_out ran)
	var lean: float = 0.0  # lean toward the door at the release: HEAD_OUT with a haul, else 0
	var carry := Vector3.ZERO  # the pace of the moving car the flight keeps (u/s, level, capped)
	var haul_carry := Vector3.ZERO  # the car's whole pace, which the haul keeps (u/s, level)
	var m1: float = 1.0  # the speed the haul's pull ends at (see pull)
	var shift := Vector3.ZERO  # where the body is let go, further down the car's side (u)
	var landed: bool = false  # the throw has touched the ground (told once)


## True when a carjack goes the way this file has it: the carjack_throw flag and the hit_feel flag
## it is the look of (without hit_feel nothing of it applies: the plain drag and throw).
static func on() -> bool:
	return FeatureFlags.enabled("carjack_throw") and FeatureFlags.enabled("hit_feel")


## The plan for a blow of strength (0..1) throwing fling metres along door (level, any length);
## flip is +1 or -1, the way it twists, face the turn (rad) of the facing at the release off facing
## the way they came from (towards the car).
static func make(
	strength: float, fling_m: float, door: Vector3, flip: float, face: float = 0.0
) -> Plan:
	var p := Plan.new()
	var s := clampf(strength, 0.0, 1.0)
	p.fling = maxf(fling_m, 0.0)
	p.door = Vector3(door.x, 0.0, door.z).normalized()
	p.apex = p.fling * lerpf(APEX_K.x, APEX_K.y, s)
	p.air = maxf(2.0 * sqrt(2.0 * p.apex / G), 0.05)
	p.skid = clampf(SKID_M / maxf(p.fling, 1e-3), 0.0, 0.5)
	p.spin = signf(flip) * minf(lerpf(SPIN.x, SPIN.y, s), SPIN_RATE * p.air / PI)
	p.rate = T_CONTACT / p.air
	p.yaw_f = atan2(-p.door.x, -p.door.z) + face
	return p


## hit()'s result res for reaction r, with "lands_in" (seconds from the blow to the body's
## touchdown, the haul if there is one and then the air: what the street hears the fall at) added
## to a carjack's throw.
static func landing(r, res: Dictionary) -> Dictionary:
	if r.jack != null:
		res["lands_in"] = (HAUL_S if r.jack.seated else 0.0) + r.jack.air
	return res


## Metres a second the flight moves across the ground, along the door (level).
static func release_speed(p: Plan) -> float:
	return (1.0 - p.skid) * p.fling / p.air


## How far across (0..1) the haul has gone x (0..1) of the way: from rest, speeding up, ending at
## speed m1 (0..2.5, in whole-haul distances per haul) -- the flight's own pace, so the body is
## not stopped at the door and started again. Under 1 the pull peaks (the yank) and eases off into
## the flight, as a short fling's slow pace asks; 0 stops at the door.
static func pull(x: float, m1: float) -> float:
	var u := clampf(x, 0.0, 1.0)
	return (3.0 - m1) * u * u + (m1 - 2.0) * u * u * u


## The hips' lift over the sill (u) at x (0..1) of the haul: up and level at the release, where
## the flight takes it on.
static func lift(x: float) -> float:
	return LIFT * sin(0.5 * PI * clampf(x, 0.0, 1.0))


## The share (0..1) of the turn to face the car done t seconds from the blow: a smoothstep over the
## plan's window, the haul's TURN share of it or, for a turn too big for TURN_RATE in that, longer.
static func turn_at(t: float, p: Plan) -> float:
	return smoothstep(p.turn_t.x, p.turn_t.x + p.turn_t.y, t)


## The facing at tau (0..1) of the flight, before the twist: the release facing, or with a haul
## whose turn runs on past the release (turn_t) the turn still to do.
static func flight_yaw(tau: float, p: Plan) -> float:
	if not p.haul or p.turn_t.x + p.turn_t.y <= HAUL_S + 1e-9:
		return p.yaw_f
	return lerp_angle(p.yaw_0, p.yaw_f, turn_at(HAUL_S + tau * p.air, p))


## The lean toward the door (rad) at x (0..1) of the haul: quick at the jerk, level at the
## release, where it is HEAD_OUT.
static func haul_lean(x: float, p: Plan) -> float:
	var u := 1.0 - clampf(x, 0.0, 1.0)
	return p.lean * (1.0 - u * u)


## The lean at tau (0..1) of the flight: held a moment past the release, gone by touchdown (the
## clip's own flip has the body by then).
static func fly_lean(tau: float, p: Plan) -> float:
	return p.lean * (1.0 - smoothstep(0.0, 1.0, tau))


## How far (u, along the car's heading) the car's pace has carried the hauled body t seconds into
## the haul: the whole pace, over the last CARRY_EASE_S of it easing (smoothstep) down to the pace
## the flight keeps. With the whole pace to the release and the flight's own after it the pace was
## stepped by (v - CARRY_MAX) from one frame to the next, a car's pace over CARRY_MAX that is.
static func carried(p: Plan, t: float) -> Vector3:
	var ease_s := minf(CARRY_EASE_S, HAUL_S)
	var from := HAUL_S - ease_s
	var d := p.haul_carry * t
	if t > from:
		var k := clampf((t - from) / ease_s, 0.0, 1.0)
		# The integral of smoothstep from 0 to k is k^3 - k^4 / 2 (of the span, in seconds).
		d -= (p.haul_carry - p.carry) * (ease_s * (k * k * k - 0.5 * k * k * k * k))
	return d


## The haul's lift still left at tau of the flight (u): it falls away as the arc takes over.
static func fly_lift(tau: float, p: Plan) -> float:
	var u := 1.0 - clampf(tau, 0.0, 1.0)
	return LIFT * u * u if p.haul else 0.0


## Scales the plan's twist down until the facing through the flight, the turn that runs on past the
## release (turn_t) and the twist together never turn faster than SPIN_RATE: the tail of that turn
## and the twist's rise overlap just after the release. Only a haul whose turn does run on.
static func fit_spin(p: Plan) -> void:
	if not p.haul or p.turn_t.x + p.turn_t.y <= HAUL_S + 1e-9:
		return
	for _i in range(24):
		if flight_rate(p) <= SPIN_RATE:
			return
		p.spin *= 0.9


## The fastest the facing turns (rad/s) through the plan's flight, turn and twist together, sampled
## RATE_SAMPLES times over its air time.
static func flight_rate(p: Plan) -> float:
	var step := 1.0 / float(RATE_SAMPLES)
	var prev := flight_yaw(0.0, p) + twist(0.0, p)
	var peak := 0.0
	for i in range(1, RATE_SAMPLES + 1):
		var cur := flight_yaw(float(i) * step, p) + twist(float(i) * step, p)
		peak = maxf(peak, absf(angle_difference(prev, cur)))
		prev = cur
	return peak / (step * p.air)


## The twist (rad) from the release facing at tau (0..1) of the flight: none at either end.
static func twist(tau: float, p: Plan) -> float:
	var s := sin(PI * clampf(tau, 0.0, 1.0))
	return p.spin * s * s


## The knockback clip's seconds at tau of the flight: the fall meets the ground at touchdown.
static func clip_at(tau: float) -> float:
	return T_CONTACT * clampf(tau, 0.0, 1.0)


## Tip and side roll (rad, as the walker's vis_tilt and vis_roll) of a body facing yaw that leans
## by lean toward door (level unit): leaning back when it faces away from it.
static func tilt_roll(lean: float, door: Vector3, yaw: float) -> Vector2:
	var f := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := Vector3(-f.z, 0.0, f.x)
	return Vector2(lean * door.dot(f), lean * door.dot(right))


## The blow's plan for reaction r (reactions.gd, a throw knocked down by cause): for a carjack
## (flag on) the arc, the air time and the skid are this plan's instead of the plain throw's, the
## knockdown's lie kept as long as it was beyond the slowed fall; null for anything else.
static func plan_down(r, cause: String, strength: float, fling_m: float) -> Plan:
	if cause != "carjack" or not on():
		return null
	var flip: float = r.w.jack_flip if r.w.jack_flip != 0.0 else 1.0 - 2.0 * float(r.w.id & 1)
	var face: float = r.w.jack_face
	var p := make(strength, fling_m, r.slide, flip, face)
	p.haul_carry = Vector3(r.w.carry.x, 0.0, r.w.carry.z)
	p.carry = p.haul_carry.limit_length(CARRY_MAX)
	p.seated = r.w.seated
	if p.carry.length_squared() > 1e-12:
		r.slide += p.carry * (p.air / maxf(1.0 - p.skid, 0.2))
		p.yaw_f = atan2(-r.slide.x, -r.slide.z) + face
	r.lift = p.apex * WS.M
	r.fly_s = p.air
	r.air = p.air
	r.skid = p.skid
	r.slide_s = p.air + SKID_S
	r.tilt = 0.0
	var fall: Array = r.steps[0]
	fall[2] = float(fall[2]) + maxf(p.air - T_CONTACT, 0.0)
	return p


## drag_out has set the haul up (r.drag: from, to, the facing at either end and the shift, which a
## drag made without one has none of): the plan learns of it and of the haul's end speed, and the
## body sits upright in the seat until the haul's first frame (the blow had put it in the release
## pose). Returns the haul's seconds (PLAIN_S with no plan).
static func begin(r) -> float:
	var p: Plan = r.jack
	if p == null:
		return PLAIN_S
	p.haul = true
	p.lean = HEAD_OUT
	p.shift = r.drag[4] if r.drag.size() > 4 else Vector3.ZERO
	p.yaw_0 = float(r.drag[2])
	var round_by := absf(angle_difference(p.yaw_0, float(r.drag[3])))
	p.turn_t = Vector2(
		TURN.x * HAUL_S, maxf((TURN.y - TURN.x) * HAUL_S, 1.5 * round_by / TURN_RATE)
	)
	fit_spin(p)
	var from: Vector3 = r.drag[0]
	var to: Vector3 = r.drag[1]
	var span := Vector2(to.x - from.x, to.z - from.z).length() / WS.M
	p.m1 = clampf(release_speed(p) * HAUL_S / maxf(span, 0.1), 0.0, 2.5)
	r.w.vis_tilt = 0.0
	r.w.vis_roll = 0.0
	return HAUL_S


## One frame of the haul (reactions.gd step): the body drawn on from the seat to beside the door
## along the pull, lifted over the sill, turning to face the car and leaning out. True once out.
## The lift is kept as the reaction's bump, so the flight that follows takes it off the feet again
## the way it takes off an arc's height (whether or not a floor puts them back on the ground).
## The car's pace is the whole of the haul's (the seat moves with the car) until it eases down to
## the flight's (carried). With no plan it is the plain haul.
static func haul(r, dt: float) -> bool:
	var w = r.w
	var p: Plan = r.jack
	if p == null:
		return _plain(r, dt)
	r.left -= dt
	var x := clampf(1.0 - r.left / HAUL_S, 0.0, 1.0)
	var k := pull(x, p.m1)
	var at := (
		(r.drag[0] as Vector3).lerp(r.drag[1], k) - p.shift * (k - smoothstep(SHIFT_AT, 1.0, k))
	)
	at += Vector3.UP * lift(x) + carried(p, HAUL_S * x)
	w.vis_off = at - w.pos
	r.bump = lift(x)
	w.yaw = lerp_angle(float(r.drag[2]), float(r.drag[3]), turn_at(HAUL_S * x, p))
	var t := tilt_roll(haul_lean(x, p), p.door, w.yaw)
	w.vis_tilt = t.x
	w.vis_roll = t.y
	w.vis_v = 0.0
	# Ends on the frame the clock reaches HAUL_S, not on the float residue left of it (which held
	# the body still for a frame at the hand-off).
	return r.left <= 1e-6


## The plain haul over PLAIN_S: drawn on from the seat out over the sill to beside the door in
## the sit pose, turning to face the car and tipping back as it comes; true once out.
static func _plain(r, dt: float) -> bool:
	var w = r.w
	r.left -= dt
	var x := clampf(1.0 - r.left / PLAIN_S, 0.0, 1.0)
	var k := smoothstep(0.0, 1.0, x)
	var at := (
		(r.drag[0] as Vector3).lerp(r.drag[1], k) + Vector3(0.0, PLAIN_LIFT * sin(PI * x), 0.0)
	)
	w.vis_off = at - w.pos
	w.yaw = lerp_angle(float(r.drag[2]), float(r.drag[3]), k)
	w.vis_tilt = -PLAIN_TILT * sin(PI * x)
	w.vis_v = 0.0
	return r.left <= 0.0


## One frame of the flight (reactions.gd _throw, after the arc's height is in the drawn feet; none
## with no plan):
## the twist, the lean easing out, the haul's lift falling away and the fall clip on its slowed
## clock. From touchdown it leaves the body as the plain throw would, and tells on_landed (the
## walker) the once.
static func fly(r, on_landed: Callable = Callable()) -> void:
	var p: Plan = r.jack
	if p == null:
		return
	var w = r.w
	var tau := clampf(r.fly_t / maxf(r.fly_s, 1e-3), 0.0, 1.0)
	var up := fly_lift(tau, p)
	w.vis_off.y += up
	r.bump += up
	w.yaw = flight_yaw(tau, p) + twist(tau, p)
	var t := tilt_roll(fly_lean(tau, p), p.door, w.yaw)
	w.vis_tilt = t.x
	w.vis_roll = t.y
	if tau < 1.0:
		w.react_t = clip_at(tau)
		w.react_rate = p.rate
	else:
		w.react_rate = 1.0
		if not p.landed:
			p.landed = true
			if on_landed.is_valid():
				on_landed.call(w)


## A step of reaction r starts on clip (reactions.gd _next_step): the seconds into the clip it
## starts at, always 0 (a mixer starts a new clip from its beginning, and the walker's clip clock
## and the slowed pace through the air count from there). A carjack's fall starts in the release
## pose, which the change of step has otherwise just levelled for a frame, facing as the haul left
## it (the step has otherwise set the facing the turn ends at, which a turn running on into the
## flight has not reached). (Only the flight itself: a car that runs over the body where it lies
## starts the fall again with no arc, lift 0.)
static func enter(r, clip: StringName) -> float:
	if r.jack == null or clip != &"knockback" or r.lift <= 0.0:
		return 0.0
	var p: Plan = r.jack
	r.w.yaw = flight_yaw(0.0, p)
	var t := tilt_roll(fly_lean(0.0, p), p.door, r.w.yaw)
	r.w.vis_tilt = t.x
	r.w.vis_roll = t.y
	return 0.0
