extends "res://tools/tests/fp_jack_kit.gd"
## What keeps a car entry sane when the world does not (drive_feature.gd, car_entry.gd, traffic's
## sim_dt, health_feature.gd): a hero knocked down while he reaches for the driver, or in the middle
## of the pull, is out of the entry on the spot (the car let go with its driver at the wheel before
## the pull, an empty car on the road after it; he stays where he fell and never glides to the
## seat); a hero pushed far from the door while he steps in is put on the spot within ALIGN_MAX s,
## not over the seconds the distance would take; at 8x the grab and the pull run at real time (the
## pull is at least PULL_MIN_S of wall time from the blow to the let-go, as at 1x) and the street
## goes back to 8x once the pull is over; and the car taken leaves no mark behind (the one the hero
## is taking is forgotten as it is claimed, and when the world is rebuilt).

const ENTRY := preload("res://scripts/fp/drive/car_entry.gd")
const HIJACK_RUN := preload("res://scripts/fp/drive/hijack.gd")
const PULL_MIN_S := 0.6
## The blow to the street back at speed: the pull, the fall, the lie and the get-up at real time.
const AFTER_MIN_S := 2.5
## The speed (m/s) a hijacked car is braked from, and how much sooner (s) and nearer (m) standing on
## the brakes stops it than the ordinary held-car brake.
const SLAM_SPEED := 7.0
const SLAM_GAIN := Vector2(0.15, 0.2)
const RUN_S := 14.0
## The hero is never nearer than this (m) to the driver's seat while he is on foot beside the car.
const SEAT_KEEP := 0.45
var health: FpFeature = null


func _init() -> void:
	if await _fixture():
		health = K.make_feature(ctx, "health")
		K.check(fails, health != null, "the health feature is registered")
		if health != null:
			await _knock("reach")
			await _knock("pull")
			await _lineup()
			await _speed(8)
			await _speed(1)
			await _stale()
			await _stuck_hijack()
			await _slam()
			await _marks()
	K.check(fails, ran.size() == 9, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_SAFETY_TEST", fails)


## A stopped car with its driver drawn and the hero on foot beside it, F pressed.
func _start() -> VH.Car:
	door_model = _model_by_key("sedan_blue")
	K.quiet_walkers(traffic)
	for f: String in ["car_doors", "carjack", "action_hijack"]:
		FeatureFlags.set_override(f, true)
	var c := _stage("stopped")
	hits.clear()
	victim = null
	var rec := {"started": false}
	_begin("stopped", c, rec)
	K.check(fails, bool(rec["started"]), "F starts the entry")
	return c


## Frames until cond is true (at most RUN_S s): the seconds taken, -1 when it never was.
func _until(cond: Callable, max_s: float = RUN_S) -> float:
	var t := 0.0
	while t < max_s:
		if cond.call():
			return t
		_frame()
		await process_frame
		t += DT
	return -1.0 if not cond.call() else t


func _beat() -> String:
	var entry: RefCounted = drive.get("entry")
	return str((entry.get("_hold") as RefCounted).get("beat")) if entry.get("kind") == "in" else ""


## The hero knocked down (not out) in the reach, or in the pull.
func _knock(when: String) -> void:
	var c := _start()
	var entry: RefCounted = drive.get("entry")
	var seat_world := (
		Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
		* ((traffic.call("door_info", c.id) as Dictionary)["seat"] as Vector3)
	)
	var cond := func() -> bool: return _beat() == "reach" if when == "reach" else _beat() == "pull"
	var got := await _until(cond)
	K.check(fails, got >= 0.0, "%s: the hero got to the %s" % [when, when])
	var p := ctx.player
	var at := p.position
	health.call("hurt", 5.0, "punch", Vector3(0.0, 0.0, 0.2 * WS.M), true)
	var label := "knocked down in the %s" % when
	K.check(fails, health.call("knocked"), "%s: he is down" % label)
	K.check(
		fails,
		(
			not bool((drive.get("hijack") as RefCounted).call("running"))
			and entry.get("kind") == ""
			and not bool(drive.get("active"))
		),
		"%s: the entry is over, he is not at the wheel (kind '%s')" % [label, entry.get("kind")]
	)
	K.check(fails, int(drive.get("_jack_id")) == -1, "%s: no car is being taken any more" % label)
	if when == "reach":
		K.check(
			fails,
			not c.hold and hits.is_empty(),
			(
				"%s: the car is let go and no one was struck (hold %s, %d blows)"
				% [label, c.hold, hits.size()]
			)
		)
		var seated: Variant = (traffic.get("occupants") as RefCounted).call("driver_of", c.id)
		K.check(fails, seated != null, "%s: its driver is still at the wheel" % label)
	else:
		K.check(
			fails,
			victim != null and not victim.dead and traffic.get("_driven") == null,
			(
				"%s: the driver is on the road, the empty car is left (driven %s)"
				% [label, traffic.get("_driven")]
			)
		)
	var nearest := INF
	for _k in range(int(5.0 / DT)):
		_frame()
		health.call("tick", DT)
		await process_frame
		nearest = minf(nearest, p.position.distance_to(seat_world))
	K.check(
		fails,
		nearest >= SEAT_KEEP * WS.M and not bool(drive.get("active")) and entry.get("kind") == "",
		(
			"%s: he stays where he fell, never near the seat (%.2f m at the nearest)"
			% [label, nearest / WS.M]
		)
	)
	K.check(
		fails,
		(
			p.position.distance_to(at) < 2.0 * WS.M
			and not bool(health.call("knocked"))
			and p.input_enabled
		),
		(
			"%s: he gets up on foot with his input back (%.2f m from where he fell)"
			% [label, p.position.distance_to(at) / WS.M]
		)
	)
	_reset()
	ran.append(when)


## A hero put far from the door as he steps into its opening is on the spot within ALIGN_MAX s.
func _lineup() -> void:
	_start()
	var entry: RefCounted = drive.get("entry")
	var got := await _until(func() -> bool: return entry.get("phase") == "step")
	K.check(fails, got >= 0.0, "line-up: the hero came to the step into the opening")
	var p := ctx.player
	# He is pushed three metres off at the moment the step gives up (its time is up): the line-up
	# starts from there, with the whole of the distance to make up.
	entry.set("_walked", ENTRY.STEP_MAX - DT)
	p.teleport(p.position + Vector3(0.0, 0.0, -3.0 * WS.M), rad_to_deg(p.yaw))
	var t_turn := -1.0
	var t := 0.0
	var longest := 0.0
	var planned := 0.0
	while t < 8.0 and entry.get("kind") == "in":
		_frame()
		await process_frame
		t += DT
		if entry.get("phase") == "turn":
			t_turn = maxf(t_turn, 0.0) + DT
			planned = float(entry.get("_len"))
			longest = maxf(longest, t_turn)
		if bool(drive.get("active")):
			break
	K.check(
		fails,
		planned > 0.5 and planned <= ENTRY.ALIGN_MAX + 1e-3 and longest <= ENTRY.ALIGN_MAX + 0.3,
		(
			"line-up: put on the spot over %.2f s of turning (at most %.1f s; planned %.2f s)"
			% [longest, ENTRY.ALIGN_MAX, planned]
		)
	)
	_reset()
	ran.append("lineup")


## The pull at sim speed `speed`: from the blow to the driver let go it takes at least PULL_MIN_S of
## real time, and the street is at 8x again once it is over.
func _speed(speed: int) -> void:
	ctx.sim.speed = speed
	var idle: float = traffic.call("sim_dt", DT)
	K.check(
		fails,
		absf(idle - DT * speed) < 1e-6,
		(
			"%dx: the street runs at %dx while no one is robbed (%.4f s per frame)"
			% [speed, speed, idle]
		)
	)
	var c := _start()
	var got := await _until(func() -> bool: return not hits.is_empty())
	K.check(fails, got >= 0.0, "%dx: the driver was struck" % speed)
	var during: float = traffic.call("sim_dt", DT)
	K.check(
		fails,
		absf(during - DT) < 1e-6,
		"%dx: the pull runs at real time (%.4f s per frame, %.4f real)" % [speed, during, DT]
	)
	var took := await _until(func() -> bool: return bool(traffic.call("jack_hauled")))
	K.check(
		fails,
		took >= PULL_MIN_S,
		(
			"%dx: the pull took %.2f s of real time from the blow (at least %.1f)"
			% [speed, took, PULL_MIN_S]
		)
	)
	var seated := await _until(func() -> bool: return bool(drive.get("active")))
	K.check(fails, seated >= 0.0, "%dx: the hero is then seated" % speed)
	# The driver's fall, lie and get-up run at real time too (not rushed to a blink at 8x): the
	# street is back at speed only once they are up.
	var back := await _until(
		func() -> bool: return absf(float(traffic.call("sim_dt", DT)) - DT * speed) < 1e-6
	)
	var aftermath := took + seated + back
	var said := "%dx: the street is back at speed %.2f s after the blow, once the driver is up "
	said += "(at least %.1f), and the car taken is no mark (taking %s)"
	K.check(
		fails,
		back >= 0.0 and aftermath >= AFTER_MIN_S and traffic.get("_taking") == -1,
		said % [speed, aftermath, AFTER_MIN_S, traffic.get("_taking")]
	)
	ctx.sim.speed = 1
	_reset()
	c = null
	ran.append("speed%d" % speed)


## No mark is left: the car being taken is forgotten when it is claimed and when the world is
## rebuilt.
func _marks() -> void:
	traffic.set("_taking", 123)
	traffic.call("on_world_rebuilt")
	K.check(fails, traffic.get("_taking") == -1, "a rebuilt world forgets the car being taken")
	var cj: RefCounted = traffic.get("carjack")
	K.check(fails, int(cj.get("victim")) == -1, "and the driver pulled out last")
	ran.append("marks")


## A mark left by a car that is gone is no reason to hold the street at real time: the car taken
## removed from the street while the hero walks to it (a cull, a teleport refill), or the world
## loaded under him, then 8x is 8x again, and letting go of it clears the mark.
func _stale() -> void:
	for how in ["removed", "loaded"]:
		var c := _start()
		var got := await _until(func() -> bool: return _beat() == "reach")
		K.check(fails, got >= 0.0, "%s: the hero got to the reach" % how)
		K.check(fails, traffic.get("_taking") == c.id, "%s: the car taken is the mark" % how)
		if how == "removed":
			(traffic.get("vehicles") as VH).remove(c)
		else:
			traffic.call("from_dict", {})
			drive.call("from_dict", {})
		_frame()
		await process_frame
		ctx.sim.speed = 8
		var dt: float = traffic.call("sim_dt", DT)
		ctx.sim.speed = 1
		K.check(
			fails,
			absf(dt - 8.0 * DT) < 1e-6,
			"%s: the car is gone and the street runs at 8x again (%.4f s per frame)" % [how, dt]
		)
		traffic.call("hold_car", c.id, false)
		K.check(
			fails,
			traffic.get("_taking") == -1,
			(
				"%s: letting go of a car that is gone clears the mark (%s)"
				% [how, traffic.get("_taking")]
			)
		)
		_reset()
		traffic.set("_taking", -1)
	ran.append("stale")


## A hijack held at the window by a car that can no longer be taken (it pulled in to park) lets him
## go after HOLD_MAX s: he drops to the road on foot, the car let go, nobody is stuck hanging.
func _stuck_hijack() -> void:
	var hj: RefCounted = drive.get("hijack")
	var c := _stage("hijack")
	hits.clear()
	victim = null
	var rec := {"started": false}
	_begin("hijack", c, rec)
	var hold := await _until(func() -> bool: return hj.get("phase") == "hold")
	K.check(fails, hold >= 0.0, "hijack: the hero hangs at the window")
	c.park_t = 0.5
	var limit: float = HIJACK_RUN.HOLD_MAX + 2.0
	var went := await _until(func() -> bool: return not bool(hj.call("running")), limit + 1.0)
	var p := ctx.player
	K.check(
		fails,
		went >= 0.0 and went <= limit and not p.carried and p.input_enabled,
		(
			"hijack: the car cannot be taken: he is let go after %.1f s (at most %.1f), on foot"
			% [went, limit]
		)
	)
	K.check(
		fails,
		not bool(drive.get("active")) and not c.hold and traffic.get("_taking") == -1,
		"and he is not at the wheel, the car is off the brakes and no mark is left"
	)
	c.park_t = -1.0
	_reset()
	ran.append("stuck")


## A hijacked car's driver stands on the brakes (hold_car with slam): the car at 7 m/s stops in a
## shorter time and distance than a held car does without it (about 1.0 s and 3.1 m against 1.3 s
## and 3.5 m).
func _slam() -> void:
	door_model = _model_by_key("sedan_blue")
	K.quiet_walkers(traffic)
	var stops := {}
	for slam: bool in [false, true]:
		var c := _stage("hijack")
		c.hold = false
		c.v = SLAM_SPEED * WS.M
		c.vel = Vector3(sin(c.yaw), 0.0, cos(c.yaw)) * c.v
		var from := c.pos
		traffic.call("hold_car", c.id, true, slam)
		var t := 0.0
		while c.v > 0.0 and t < 5.0:
			_traffic_step(DT)
			t += DT
		stops[slam] = Vector2(t, (c.pos - from).length() / WS.M)
		traffic.call("hold_car", c.id, false)
		_reset()
	var soft: Vector2 = stops[false]
	var hard: Vector2 = stops[true]
	var said := "standing on the brakes stops the car sooner: %.2f s and %.2f m, held %.2f s and "
	said += "%.2f m (at least %.2f s and %.2f m sooner)"
	K.check(
		fails,
		hard.x <= soft.x - SLAM_GAIN.x and hard.y <= soft.y - SLAM_GAIN.y,
		said % [hard.x, hard.y, soft.x, soft.y, SLAM_GAIN.x, SLAM_GAIN.y]
	)
	ran.append("slam")
