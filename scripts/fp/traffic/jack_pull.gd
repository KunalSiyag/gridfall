extends RefCounted
## How the driver the hero pulls out of a car goes, from the seat to the road (the carjack_throw
## flag, which needs hit_feel: on(); docs/fp/ARCHITECTURE.md, Integration: driving), as one sequence
## on the clips the walkers already have. reactions.gd starts it (_plan_down for the blow, drag_out
## for the haul) and runs its two hooks (haul, fall); this file holds the curves, each a pure
## function of time so a test can sample them.
## The haul (HAUL_S, in the sit pose, facing as they sat): the hero has the driver by the collar and
## drags them out of the seat sideways over the sill, speeding up, the body leaning toward the road
## (a roll of HAUL_ROLL rad at the release) and back (a tip of HAUL_TIP rad: pulled by the collar
## toward the hero's hip, the legs trail into the car). Where the open door asks (carjack.gd,
## jack_landing.gd) the place they come out at is a little further down the car's side than
## straight out of the seat: they go straight out over the sill first and drift there as they go.
## The drawn hips come down with the tip as they come out (haul_drop), so they are not sat on the
## air for long.
## Out of a body with no door that opens (a bus, a truck, a bicycle, a scooter: jack_cab.gd) the
## hips are lifted over its solid side (Plan.lift, u) while the body is across it (Plan.wall_k, the
## share of the way across where the side is), and come down only once past it, so the driver is
## never drawn through the bodywork or dropped from the cab through the wall.
## The fall (FALL_S, still in the sit pose): they are let go beside the door, slide out a little
## further on the road, sit down on it and fall back, the body tipped back about the hips as far as
## FALL_BACK while its drawn hips are lowered so that its lowest part is on the road (drop_at): it
## never leaves the ground, and nothing rises above where it started. The hips touch the road
## (SEAT_CONTACT, told by on_landed) and then the back. It lies there along the car's side (head to
## the rear, feet toward the front) in the get-up clip's low first pose (the walker blends to it
## over BLEND_S as the tip comes out of the drawn body, blend_tip and blend_drop), for the lie, and
## gets up.
## A car that is moving carries the body along at its own pace through the haul (the seat moves
## with it; it eases down over the last CARRY_EASE_S to the pace the slide keeps, at most CARRY_MAX
## of it), and the slide goes on at that pace, so the body is neither left hanging in the air
## behind the car nor stopped dead as it comes out.
## With no plan the haul is the plain one, the sit pose tipped back (PLAIN_S). Someone not drawn at
## the wheel (standing by the door) is knocked down where they stand, with the plain knock-down
## clip, and told landed STAND_CONTACT s in.

const WS := preload("res://scripts/fp/world_scale.gd")
## The haul: seconds, the roll toward the road (rad) and the tip back (rad) at the release. It takes
## HAUL_S so that a pull reads as one (the hero's hands are on the driver the whole way out: 0.7 s,
## about 1.3 m/s on average and 2.4 m/s at most, the last moment).
const HAUL_S := 0.7
const HAUL_ROLL := 0.3
const HAUL_TIP := 0.6
## Where the body is let go further down the car's side than straight out of the seat (carjack.gd,
## to clear the open door), it goes straight out over the sill first and drifts there only after
## the share SHIFT_AT of the way across.
const SHIFT_AT := 0.25
## A driver sat above the road (a cab: the root begins higher than where it is let go) comes down
## over the first DROP_AT of the way across, so that it is on the road by the time it is past the
## sill, never above it.
const DROP_AT := 0.5
## Over a solid side (Plan.wall_k) the body is lifted until WALL_PAST of the way across beyond it,
## which takes the haul CAB_HAUL_S and ends no faster than CAB_M1 (the haul's end speed, see pull):
## the way down the outside of a cab is long, and it is not to be a drop.
const WALL_PAST := 0.22
const CAB_HAUL_S := 1.0
const CAB_M1 := 0.6
## Over a solid side at the body's edge (a cab's skin, wall_k at least WARP_MIN: the way down its
## outside is long) the haul runs its way across fast and eases out (the time is warped by
## 1 - (1 - x)^CAB_WARP), and the body is let down over the rest of the haul, from where it is past
## the side (cab_x_past) to the end: it is lowered, not dumped in a tenth of a second.
const CAB_WARP := 2.2
const WARP_MIN := 0.3
## The fall: seconds, the tip back (rad) the body lies at, the tip at which its hips are on the road
## and the walker's crossfade to the lying pose (people.gd XFADE), over which the tip comes out.
const FALL_S := 0.4
const FALL_BACK := deg_to_rad(80.0)
const SEAT_CONTACT := deg_to_rad(55.0)
const BLEND_S := 0.25
## The sit pose's hips are SIT_HIP (body metres) up: the walker's lean turns about them (walkers.gd
## vis_pivot) while it is hauled and falls. Tipped back by an angle it has to be lowered DROP_K per
## rad, up to DROP_MAX (body metres), for its lowest part to rest on the road, within a few
## centimetres (fitted to the rig's sit pose, on its skinned vertices: fp_jack_flow_test reads the
## lowest of them), for a body of REF_H metres.
const SIT_HIP := 0.59
const DROP_K := 0.6
const DROP_MAX := 0.5
const REF_H := 1.75
## The slide after the release: seconds (eased out), taking the root out beside the door as the
## body falls back (it is the hips the fall puts further out).
const SLIDE_S := 0.5
## The pace of a moving car the slide keeps (m/s, at most). A moving car carries the haul at its
## whole pace; over the last CARRY_EASE_S of it that eases down (smoothly) to the slide's, so the
## body is not stopped dead from one frame to the next as the car drives on from under it.
const CARRY_MAX := 5.0 * WS.M
const CARRY_EASE_S := 0.2
## The plain haul (no plan, reactions.gd drag_out): seconds, the hips' lift over the sill and the
## tip back (rad) at its middle.
const PLAIN_S := 0.5
const PLAIN_LIFT := 0.2 * WS.M
const PLAIN_TILT := 0.5
## The seated driver is drawn in the sit pose (held at DRAG_AT) through the haul and the fall.
const DRAG_CLIP := &"sit"
const DRAG_AT := 1.0
## Someone standing: the knock-down clip's seconds when its back is on the ground.
const STAND_CONTACT := 0.3


## One pull-out's numbers: made when the blow is planned, read as the haul and the fall run.
class Plan:
	extends RefCounted
	var door := Vector3.ZERO  # level unit: out of the car, the way they are pulled
	var seated: bool = false  # drawn at the wheel, so hauled out first (the walker's seated)
	var haul: bool = false  # hauled out of a seat first (drag_out ran)
	var lean: float = 0.0  # roll to the door at the release: HAUL_ROLL for one drawn seated, else 0
	var tip: float = 0.0  # tip back at the release: HAUL_TIP for one drawn seated, else 0
	var carry := Vector3.ZERO  # the pace of the moving car the slide keeps (u/s, level, capped)
	var haul_carry := Vector3.ZERO  # the car's whole pace, which the haul keeps (u/s, level)
	var m1: float = 1.0  # the speed the haul's pull ends at (see pull)
	var shift := Vector3.ZERO  # where the body is let go, further down the car's side (u)
	var lift: float = 0.0  # hips raised over the body's solid side at its crossing (u; 0 for none)
	var haul_s: float = HAUL_S  # the haul's seconds (CAB_HAUL_S over a solid side)
	var wall_k: float = 0.0  # share of the way across at which the side is (with lift)
	var roll0: float = 0.0  # the roll toward the door they were leaning at as the haul began
	var tip0: float = 0.0  # the tip back they were already at (a sit-up is negative)
	var fall_t: float = 0.0  # seconds since the fall began
	var lie_s: float = 0.0  # seconds it lies in the lying pose before the get-up plays
	var lie_t: float = 0.0  # seconds since the lying step began
	var landed: bool = false  # the body has touched the ground (told once)


## True when a carjack goes the way this file has it: the carjack_throw flag and the hit_feel flag
## it is the look of (without hit_feel nothing of it applies: the plain drag and knock-down).
static func on() -> bool:
	return FeatureFlags.enabled("carjack_throw") and FeatureFlags.enabled("hit_feel")


## True while reaction r (a knock-down) has the person down: the stagger before the fall, the
## knock-down and the get-up, and for a driver pulled out the haul and the sit-down too, but not the
## shout and the run that follow the get-up (the plan stays set until the reaction is over).
static func is_down(r) -> bool:
	return (
		r.stagger_left > 0.0
		or r.w.react in [&"knockback", &"get_up"]
		or (r.jack != null and r.w.react == DRAG_CLIP)
	)


## The plan for a blow that drops the driver drop_m metres along door (level, any length) beyond the
## place the haul ends at, for reaction r (reactions.gd, a knock-down by cause "carjack"): the
## slide, with the pace of a moving car added, and no height at all. A driver drawn at the wheel
## sits down and lies back for lie seconds, then the get-up of up_s (the steps this puts in r's,
## in place of the knock-down's). Null with the flags off.
static func plan_down(r, door: Vector3, drop_m: float, lie: float, up_s: float) -> Plan:
	if not on():
		return null
	var p := Plan.new()
	p.door = Vector3(door.x, 0.0, door.z).normalized()
	p.seated = r.w.seated
	p.lean = HAUL_ROLL if p.seated else 0.0
	p.tip = HAUL_TIP if p.seated else 0.0
	p.haul_carry = Vector3(r.w.carry.x, 0.0, r.w.carry.z)
	p.carry = p.haul_carry.limit_length(CARRY_MAX)
	p.lie_s = lie
	r.slide = p.door * (maxf(drop_m, 0.0) * WS.M) + p.carry * (0.5 * SLIDE_S)
	r.slide_s = SLIDE_S
	r.lift = 0.0
	r.air = 0.0
	r.tilt = 0.0
	if p.seated:
		r.steps = [["place", DRAG_CLIP, FALL_S], ["place", &"get_up", lie + up_s]]
	return p


## hit()'s result res for reaction r with "lands_in" (seconds from the blow to the body's
## touchdown, the haul if there is one and then the fall to the road: what the street hears the
## landing at) added to a carjack's pull-out.
static func landing(r, res: Dictionary) -> Dictionary:
	if r.jack != null:
		res["lands_in"] = (r.jack.haul_s + contact_s(r.jack)) if r.jack.seated else STAND_CONTACT
	return res


## How far across (0..1) the haul has gone x (0..1) of the way: from rest, speeding up, ending at
## speed m1 (0..2.5, in whole-haul distances per haul) -- the slide's own pace, so the body is not
## stopped at the door and started again. Under 1 the pull peaks (the yank) and eases off into the
## slide, as a short drop's slow pace asks; 0 stops at the door.
static func pull(x: float, m1: float) -> float:
	var u := clampf(x, 0.0, 1.0)
	return (3.0 - m1) * u * u + (m1 - 2.0) * u * u * u


## The share (0..1) of the lift over a solid side at k (0..1) of the way across when the side is at
## wall_k: eased up from the start to just before it, held across it, and taken down as the body is
## let down (down, 0..1: cab_x_past on), so that it is 0 again as the haul ends.
static func hump(k: float, wall_k: float, down: float) -> float:
	return smoothstep(0.0, maxf(wall_k - 0.1, 0.15), k) * (1.0 - down)


## How far across (0..1) the haul has gone x (0..1) of the way over a solid side: the plain haul's
## curve, with the time warped (CAB_WARP) over a side at the body's edge.
static func cab_pull(x: float, m1: float, wall_k: float) -> float:
	var u := clampf(x, 0.0, 1.0)
	return pull(1.0 - pow(1.0 - u, CAB_WARP) if wall_k >= WARP_MIN else u, m1)


## The share (0..1) of the haul's time at which the body is past the solid side at wall_k (the
## thighs trail WALL_PAST of the way beyond it) and may be let down.
static func cab_x_past(wall_k: float, m1: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for _i in range(18):
		var mid := 0.5 * (lo + hi)
		if cab_pull(mid, m1, wall_k) < wall_k + WALL_PAST:
			lo = mid
		else:
			hi = mid
	return hi


## The roll toward the door (rad) at x (0..1) of the haul: quick at the jerk, level at the release,
## where it is the plan's lean.
static func haul_lean(x: float, p: Plan) -> float:
	var u := 1.0 - clampf(x, 0.0, 1.0)
	return lerpf(p.roll0, p.lean, 1.0 - u * u)


## The tip back (rad) at x (0..1) of the haul: the same curve to the plan's tip.
static func haul_tip(x: float, p: Plan) -> float:
	var u := 1.0 - clampf(x, 0.0, 1.0)
	return lerpf(p.tip0, p.tip, 1.0 - u * u)


## The tip back (rad) t seconds into the fall: from where the haul left it to FALL_BACK, speeding up
## as a body falling does.
static func fall_tip(t: float, p: Plan) -> float:
	var x := clampf(t / FALL_S, 0.0, 1.0)
	return lerpf(p.tip, FALL_BACK, x * x)


## Seconds into the fall at which the hips touch the road (the tip is SEAT_CONTACT).
static func contact_s(p: Plan) -> float:
	if not p.seated:
		return STAND_CONTACT
	var span := maxf(FALL_BACK - p.tip, 1e-3)
	return FALL_S * sqrt(clampf((SEAT_CONTACT - p.tip) / span, 0.0, 1.0))


## The drawn hips' lowering (body metres) that keeps the sit pose tipped back by tip rad resting on
## the road, by its lowest bone: 0 upright.
static func drop_at(tip: float) -> float:
	return minf(DROP_K * tip, DROP_MAX)


## The lowering (body metres) in the haul, the tip tip rad and the root depth (body metres, 0 or
## more) still under the road level it is hauled up to (the seat sits below it: the root rises from
## the car's floor to the road as it comes out): drop_at less the depth, so the lowest bone is on
## the road once the tip has lifted the feet as far as the depth, and the hips come down smoothly,
## not up as the root rises and then down.
static func haul_drop(tip: float, depth: float) -> float:
	return maxf(drop_at(tip) - depth, 0.0)


## The tip back (rad) the drawn body still has while the lying pose comes in, k (1 to 0) of the way
## from the fall's end to the lying pose: with the square of the way, so it is out of the body
## before the clip is all the way in (the lying pose is itself a tip of about 90 degrees).
static func blend_tip(k: float) -> float:
	var x := clampf(k, 0.0, 1.0)
	return FALL_BACK * x * x


## The lowering (body metres) it still has at the same moment. The lying pose's own hips are low
## (the clip's first pose rests them about 0.07 m up), so as it crossfades in the sit pose's hips
## come down by themselves and the lowering that held the lowest bone on the road would sink the
## body into it: it goes out with the cube of the way, faster than the tip does (fitted on the
## skinned body: fp_jack_flow_test reads the lowest vertex of it over every frame).
static func blend_drop(k: float) -> float:
	var x := clampf(k, 0.0, 1.0)
	return DROP_MAX * x * x * x


## How far (u, along the car's heading) the car's pace has carried the hauled body t seconds into
## the haul: the whole pace, over the last CARRY_EASE_S of it easing (smoothstep) down to the pace
## the slide keeps.
static func carried(p: Plan, t: float) -> Vector3:
	var ease_s := minf(CARRY_EASE_S, p.haul_s)
	var from := p.haul_s - ease_s
	var d := p.haul_carry * t
	if t > from:
		var k := clampf((t - from) / ease_s, 0.0, 1.0)
		# The integral of smoothstep from 0 to k is k^3 - k^4 / 2 (of the span, in seconds).
		d -= (p.haul_carry - p.carry) * (ease_s * (k * k * k - 0.5 * k * k * k * k))
	return d


## Roll (rad, as the walker's vis_roll) of a body facing yaw that leans by lean toward door (level
## unit): positive toward the body's right.
static func roll_to(lean: float, door: Vector3, yaw: float) -> float:
	var right := Vector3(-cos(yaw), 0.0, sin(yaw))
	return lean * door.dot(right)


## Sets the haul of reaction r up (reactions.gd drag_out; nothing for one not knocked down and
## standing): the driver drawn in the sit pose from from (the seat, facing from_yaw) to where the
## blow found them, shift (a world offset, u) further down the car's side, then the fall. lean0:
## the roll to the door and the sit-up they were at (x, y; rad), then the lift over a solid side
## (u) and the share of the way across where it is (z, w; both 0 for a door that opens).
static func drag_out(
	r, from: Vector3, from_yaw: float, shift: Vector3, lean0 := Vector4.ZERO
) -> void:
	if r == null or r.mode != "place" or not r.down:
		return
	var w = r.w
	if r.jack != null:
		r.jack.roll0 = lean0.x
		r.jack.tip0 = -lean0.y
		r.jack.lift = lean0.z
		r.jack.wall_k = lean0.w
		r.jack.haul_s = CAB_HAUL_S if lean0.w > 0.0 else HAUL_S
	r.steps.push_front(["place", w.react, r.left])
	r.drag = [from, w.pos + w.vis_off, from_yaw, from_yaw if r.jack != null else w.yaw, shift]
	r.mode = "drag"
	r.left = begin(r)
	w.react = DRAG_CLIP
	w.react_t = DRAG_AT
	w.react_rate = 0.0
	w.yaw = from_yaw
	w.vis_off = from - w.pos


## The plan learns of the haul (r.drag: from, to, the facing at either end and the shift) and of its
## end speed, and the body sits upright in the seat until the haul's first frame (the blow had put
## it in the release pose). Returns the haul's seconds (PLAIN_S with no plan).
static func begin(r) -> float:
	var p: Plan = r.jack
	if p == null:
		return PLAIN_S
	p.haul = true
	r.w.vis_pivot = SIT_HIP
	p.shift = r.drag[4] if r.drag.size() > 4 else Vector3.ZERO
	var from: Vector3 = r.drag[0]
	var to: Vector3 = r.drag[1]
	var span := Vector2(to.x - from.x, to.z - from.z).length() / WS.M
	var slide := Vector2(r.slide.x, r.slide.z) - Vector2(p.carry.x, p.carry.z) * (0.5 * SLIDE_S)
	var pace := 2.0 * slide.length() / WS.M / SLIDE_S
	p.m1 = clampf(pace * p.haul_s / maxf(span, 0.1), 0.0, 2.5)
	if p.wall_k > 0.0:
		p.m1 = minf(p.m1, CAB_M1)
	r.w.vis_tilt = 0.0
	r.w.vis_roll = 0.0
	return p.haul_s


## One frame of the haul (reactions.gd step): the body drawn on from the seat to beside the door
## along the pull, leaning out and back, the hips coming down once over the sill. True once out. The
## car's pace is the whole of the haul's (the seat moves with the car) until it eases down to the
## slide's (carried). With no plan it is the plain haul.
static func haul(r, dt: float) -> bool:
	var w = r.w
	var p: Plan = r.jack
	if p == null:
		return _plain(r, dt)
	r.left -= dt
	var x := clampf(1.0 - r.left / p.haul_s, 0.0, 1.0)
	var k := cab_pull(x, p.m1, p.wall_k)
	var at: Vector3 = (
		(r.drag[0] as Vector3).lerp(r.drag[1], k) - p.shift * (k - smoothstep(SHIFT_AT, 1.0, k))
	)
	var up := 0.0
	if p.wall_k > 0.0:
		var y0 := (r.drag[0] as Vector3).y
		var down := smoothstep(cab_x_past(p.wall_k, p.m1), 1.0, x)
		up = hump(k, p.wall_k, down)
		at.y = lerpf(y0, (r.drag[1] as Vector3).y, down)
		at.y += p.lift * up
	elif (r.drag[0] as Vector3).y > (r.drag[1] as Vector3).y:
		at.y = lerpf(
			(r.drag[0] as Vector3).y, (r.drag[1] as Vector3).y, smoothstep(0.0, DROP_AT, k)
		)
	at += carried(p, p.haul_s * x)
	w.vis_off = at - w.pos
	w.yaw = float(r.drag[2])
	var tip := haul_tip(x, p)
	var depth := maxf((r.drag[1] as Vector3).y - at.y, 0.0) * REF_H / (WS.M * float(w.h_m))
	# Lifted over a side the hips are not lowered by the tip too: that comes as they come down.
	_pose(r, tip, haul_drop(tip, depth) * (1.0 - up), roll_to(haul_lean(x, p), p.door, w.yaw))
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


## One frame of the fall (reactions.gd step, at the end of the frame, in a plan's steps; the
## standing one has only the touchdown): a seated driver's sit-down and lying back, then the lying
## pose held for the lie and the tip coming out over BLEND_S. Tells on_landed (the walker) the once
## as the hips touch the road.
static func fall(r, dt: float, on_landed: Callable = Callable()) -> void:
	var p: Plan = r.jack
	if p == null or r.mode != "place":
		return
	var w = r.w
	if not p.seated:
		p.fall_t += dt
		_touch(p, w, on_landed, p.fall_t >= STAND_CONTACT)
		return
	if w.react == DRAG_CLIP:
		p.fall_t += dt
		w.react_rate = 0.0
		# Told before the body is drawn lowered, so the bus has where it lies on the road.
		_touch(p, w, on_landed, p.fall_t >= contact_s(p))
		var x := clampf(p.fall_t / FALL_S, 0.0, 1.0)
		var tip := fall_tip(p.fall_t, p)
		_pose(r, tip, drop_at(tip), roll_to(p.lean * (1.0 - x), p.door, w.yaw))
	elif w.react == &"get_up":
		p.lie_t += dt
		# The clip crossfades in as time runs (a clip held at rate 0 never gets there): it plays
		# the first BLEND_S of the get-up, holds that low pose for the rest of the lie, plays on.
		w.react_rate = 0.0 if BLEND_S <= p.lie_t and p.lie_t < p.lie_s else 1.0
		var k := 1.0 - clampf(p.lie_t / BLEND_S, 0.0, 1.0)
		if k > 0.0:
			_pose(r, blend_tip(k), blend_drop(k), 0.0)
		else:
			# Out of the tip altogether, whatever the step of the clock was; and with it the lean's
			# pivot (the sit pose's hips), so a blow on the one running off tips about their own
			# hips again, not about the seat's for the rest of the reaction.
			w.vis_tilt = 0.0
			w.vis_roll = 0.0
			w.vis_pivot = 0.0


## Draws the sit pose tipped back by tip rad, rolled toward the door by roll rad, with the hips
## lowered by drop (body metres): the walker's tilt about the hips and the lowering as a height
## that reactions.gd takes out again before the next frame's movement (bump). The lowering is
## drop's whole, not one more on the bump of the haul's last frame.
static func _pose(r, tip: float, drop: float, roll: float) -> void:
	var w = r.w
	w.vis_tilt = -tip
	w.vis_roll = roll
	var up: float = -drop * WS.M * float(w.h_m) / REF_H
	w.vis_off.y += up - r.bump
	r.bump = up


static func _touch(p: Plan, w, on_landed: Callable, due: bool) -> void:
	if due and not p.landed:
		p.landed = true
		if on_landed.is_valid():
			on_landed.call(w)
