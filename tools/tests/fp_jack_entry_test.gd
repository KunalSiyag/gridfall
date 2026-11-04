extends "res://tools/tests/fp_jack_kit.gd"
## Every way into a vehicle with someone in it, table-driven (drive_feature.gd board / jump_across,
## car_entry.gd, jack_hold.gd, hijack.gd, carjack.gd): the hero's hands are on the occupant (the
## strike pose's pull goal, both hand targets) for GRAB_MIN_S before the occupant is struck down
## (person_hit, cause carjack) and he is not seated until SEAT_GAP_S after that, for a stopped car,
## a crawling one, a moving one (the action hijack: the car is stopped under him, then the same
## pull), one whose driver is not drawn (the cap lowered: it is drawn for him), a bus, a delivery
## truck, a bicycle and a scooter (no door of their own: he reaches in from the side and takes the
## wheel once they are out); and where there is no taking it, nothing is taken without the grab: a
## door that cannot be reached (the car is let go and the driver stays, no blow, no seat), a street
## with no sidewalk (the driver is put down and stays on the road, never deleted), a walk to the
## door that fails (it starts again from where the hero stands once, then the car is let go with the
## toast), a driver who never gets drawn (the door waits for it, then the same); a hijack aborted in
## the pull leaves no ghost at the wheel and no mark that would seat the hero without a pull. With
## the car_doors flag off the old instant seat is as it was (the driver is still pulled out, hauled
## and put down, not deleted).

## The hands are on the occupant at least GRAB_MIN_S before the blow, the hero seated at least
## SEAT_GAP_S (the door-less ones SEAT_GAP_DOORLESS_S: he takes the wheel at once) after it.
const GRAB_MIN_S := 0.3
## The wrists are on both grips (within HANDS_TOL m) for at least HANDS_MIN_S before the blow.
const HANDS_TOL := 0.15
const HANDS_MIN_S := 0.25
const SEAT_GAP_S := 1.0
const SEAT_GAP_DOORLESS_S := 0.5
const RUN_S := 14.0
## How long a driver put down with no sidewalk to go to is followed, and how far it must walk off.
const WALK_OFF_S := 6.0
const WALK_OFF_MIN := 0.8
## Frames the hauled walker may share the car with a body drawn at its wheel (none).
const PROXY_MAX := 0
var toasts: Array[String] = []
## How far (m) the wrists were from the grips at best, this frame.
var _gap: float = INF


func _init() -> void:
	if await _fixture():
		ctx.bus.toast.connect(func(m: String, _k: String) -> void: toasts.append(m))
		await _rows()
	K.check(fails, ran.size() == 1, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_ENTRY_TEST", fails)


# ------------------------------------------------------------------ the table


## The rows: name, how the car is staged and entered, and what must hold. grab:   the hands are on
## the occupant for GRAB_MIN_S before the blow, and he sits SEAT_GAP_S after it refuse: no blow, no
## seat: the car is let go and the driver stays (drawn at its wheel, car not held) instant: the
## legacy instant take (the car_doors flag off): blow and seat in the same frame, the driver pulled
## out and put down (never deleted) gone:   the carjack flag off: the old way, the ambient driver
## simply gone (no blow)
func _rows() -> void:
	var m := _model_by_key("sedan_blue")
	var lists := [
		["stopped car", "stopped", "grab"],
		["crawling car", "crawling", "grab"],
		["moving car, the action hijack", "hijack", "grab"],
		["hijack, driver not drawn (cap 0)", "undrawn_hijack", "grab"],
		["hijack aborted in the pull", "hijack_abort", "abort"],
		["driver not drawn (cap 0)", "undrawn", "grab"],
		["door that cannot be reached", "blocked", "refuse"],
		["walk to the door fails twice", "walkfail", "refuse_late"],
		["driver never drawn", "unready", "refuse_late"],
		["no sidewalk edge anywhere", "no_edge", "grab"],
		["bus", "bus", "grab_doorless"],
		["delivery truck", "truck", "grab_doorless"],
		["bicycle", "bike", "grab_doorless"],
		["scooter", "scooter", "grab_doorless"],
		["car_doors off", "doors_off", "instant"],
		["carjack off", "jack_off", "gone"],
	]
	for row: Array in lists:
		var r := await _run(m, str(row[1]))
		_judge(str(row[0]), r, str(row[2]))
	ran.append("rows")


## One entry of kind `how` into a car of model m: the record of the run.
func _run(m: int, how: String) -> Dictionary:
	door_model = m
	K.quiet_walkers(traffic)
	for f: String in [
		"car_doors", "carjack", "action_hijack", "heavy_motors", "bike_ride", "scooters"
	]:
		FeatureFlags.set_override(f, true)
	if how == "doors_off":
		FeatureFlags.set_override("car_doors", false)
	if how == "jack_off":
		FeatureFlags.set_override("carjack", false)
	var c := _stage(how)
	hits.clear()
	victim = null
	hero_post.clear()
	var rec := _blank(how)
	var t0 := toasts.size()
	var t := 0.0
	var seated_frames := 0
	_begin(how, c, rec)
	var pose: Variant = _pose()
	var more := int(WALK_OFF_S / DT) if how == "no_edge" else 40
	var frames := int((RUN_S + (WALK_OFF_S if how == "no_edge" else 0.0)) / DT)
	for _step in range(frames):
		_tick(how, rec, t)
		_frame()
		hero_fresh = false
		await process_frame
		t += DT
		_note(rec, t, pose, c)
		if victim != null and not rec.has("victim_at"):
			rec["victim_at"] = victim.pos
		seated_frames += 1 if float(rec["seat_t"]) >= 0.0 else 0
		if seated_frames > more or _enough(how, rec, t, t0):
			break
	_close(rec, c, t0)
	_reset()
	return rec


## A row's record before it runs.
func _blank(how: String) -> Dictionary:
	return {
		"started": false,
		"hit_t": -1.0,
		"seat_t": -1.0,
		"grab_before": 0.0,
		"first_react": "",
		"driver_kept": false,
		"held": false,
		"victim_alive": false,
		"on_foot": false,
		"drawn_at_grab": false,
		"proxy_after": 0,
		"aborted": false,
		"end_react": "",
		"walked_off": 0.0,
		"f_t": -1.0,
		"tries": 0,
		"fails": 0,
		"how": how,
		"hands_on": 0.0,
		"toast": false,
		"jackable": true,
	}


## True when a row that never ends in a seat has shown what it has to (a door that cannot be
## reached; a hijack let go of, 1.5 s on; a walk or a driver that gave the car up, with its toast).
func _enough(how: String, rec: Dictionary, t: float, t0: int) -> bool:
	if how == "blocked":
		return t > 3.0
	if how == "hijack_abort":
		return bool(rec["aborted"]) and t > 1.5 + float(rec["f_t"])
	if how in ["walkfail", "unready"] and toasts.size() > t0:
		rec["toast_t"] = rec.get("toast_t", t)
		return t > float(rec["toast_t"]) + 0.3
	return false


## What the end of a run adds to the record: what is left at the car and of the driver.
func _close(rec: Dictionary, c: VH.Car, t0: int) -> void:
	rec["driver_kept"] = (traffic.get("occupants") as RefCounted).call("driver_of", c.id) != null
	rec["held"] = c.hold
	rec["victim_alive"] = victim != null and not victim.dead
	rec["end_react"] = str(victim.react) if victim != null else ""
	if victim != null and rec.has("victim_at"):
		var at: Vector3 = rec["victim_at"]
		rec["walked_off"] = Vector2(victim.pos.x - at.x, victim.pos.z - at.z).length() / WS.M
	rec["tries"] = int(drive.get("_jack_tries"))
	rec["toast"] = toasts.size() > t0 and toasts[toasts.size() - 1].begins_with("Can't get to")
	rec["jackable"] = bool(traffic.call("jackable", c.id))
	rec["on_foot"] = not bool(drive.get("active")) and not bool(drive.call("_climbing"))


## What the frame at time t adds to the record: the blow, the seat, the seconds the hands were on.
func _note(rec: Dictionary, t: float, pose: Variant, c: VH.Car) -> void:
	var occ: RefCounted = traffic.get("occupants")
	if not hits.is_empty() and float(rec["hit_t"]) < 0.0:
		rec["hit_t"] = t
		rec["first_react"] = str(victim.react) if victim != null else ""
	if bool(drive.get("active")) and float(rec["seat_t"]) < 0.0:
		rec["seat_t"] = t
	# The driver was hauled out: no body is drawn at the wheel of the car they came out of.
	if victim != null and not victim.dead and occ.call("driver_of", c.id) != null:
		rec["proxy_after"] = int(rec["proxy_after"]) + 1
	# Both his hands (the rig's wrists) are on the two grips.
	if float(rec["hit_t"]) < 0.0 and hero_post.has("LeftHand"):
		var on := _hands_on_grips(c)
		rec["hands_on"] = float(rec["hands_on"]) + (DT if on else 0.0)
		rec["gap"] = minf(float(rec.get("gap", INF)), _gap)
	if pose == null or float(rec["hit_t"]) >= 0.0 or float(pose.get("_pull_goal")) <= 0.5:
		return
	if (
		(pose.get("_pull_hands") as PackedVector3Array).size() == 2
		and float(pose.get("_pull")) > 0.5
	):
		rec["grab_before"] = float(rec["grab_before"]) + DT
		# The body the hands close on is there, drawn at the wheel (not a point above the seat).
		if float(rec["grab_before"]) <= 3.0 * DT:
			rec["drawn_at_grab"] = occ.call("driver_of", c.id) != null


## True when the hero's two wrists are on car c's driver's collar and near upper arm (either way
## round), within HANDS_TOL m.
func _hands_on_grips(c: VH.Car) -> bool:
	var feet: Vector3 = ctx.player.position
	# The arm the hold keeps to (it settles on one: the nearer arm can change as the body rolls).
	var held: RefCounted = (drive.get("entry") as RefCounted).get("_hold")
	# Before the hold begins (the walk to the door) it has no hero to read a reach from yet.
	if not bool(held.call("running")):
		return false
	var side := str(held.get("_arm_side"))
	# The highest the hands may go is the hold's own (his head, and over a cab a little more).
	var top := float(held.call("_top"))
	var g: Dictionary = traffic.call("jack_grips", c.id, feet, top, side)
	if not (g.get("collar", Vector3(NAN, NAN, NAN)) as Vector3).is_finite():
		return false
	if not (g["arm"] as Vector3).is_finite():
		return false
	var lh: Vector3 = hero_post["LeftHand"]
	var rh: Vector3 = hero_post["RightHand"]
	var a: float = maxf(lh.distance_to(g["collar"]), rh.distance_to(g["arm"])) / WS.M
	var b: float = maxf(lh.distance_to(g["arm"]), rh.distance_to(g["collar"])) / WS.M
	_gap = minf(a, b)
	return _gap <= HANDS_TOL


## What a row does to the entry as it runs: the walk made to fail, the driver kept from being
## drawn, the hijack let go of in the first frame of the haul.
func _tick(how: String, rec: Dictionary, t: float) -> void:
	var entry: RefCounted = drive.get("entry")
	match how:
		"walkfail":
			var due := t > 0.4 and t > float(rec["f_t"]) + 0.2 and int(rec["fails"]) < 2
			if entry.get("phase") == "walk" and due:
				entry.set("_walked", 99.0)
				rec["fails"] = int(rec["fails"]) + 1
				rec["f_t"] = t
		"unready":
			if entry.get("kind") == "in":
				entry.set("ready", func() -> bool: return false)
		"hijack_abort":
			if not hits.is_empty() and not bool(rec["aborted"]):
				rec["aborted"] = true
				rec["f_t"] = t
				drive.call("exit", true)


func _pose() -> Variant:
	var rig: Variant = ctx.player.avatar.get("rig")
	return (rig as RefCounted).get("strike_pose") if rig is RefCounted else null


func _judge(label: String, r: Dictionary, want: String) -> void:
	var hit := float(r["hit_t"])
	var seat := float(r["seat_t"])
	var note := "  note: %s: started %s, blow %.2f s, seat %.2f s, hands on %.2f s before the "
	note += "blow, wrists on the grips %.2f s (at best %.2f m off)"
	print(
		note % [label, r["started"], hit, seat, r["grab_before"], r["hands_on"], r.get("gap", INF)]
	)
	match want:
		"grab", "grab_doorless":
			_judge_grab(label, r, want)
		"refuse", "refuse_late":
			_judge_refuse(label, r, want)
		"abort":
			# The hijack let go of in the haul: the driver is out and the car has none (nobody is
			# drawn at its wheel, it is nothing to be jacked): no ghost, and no mark that would
			# have the hero seated, pull-less, the next time.
			var ok := hit >= 0.0 and bool(r["aborted"]) and seat < 0.0 and bool(r["on_foot"])
			ok = ok and int(r["proxy_after"]) <= PROXY_MAX and not bool(r["driver_kept"])
			var said := "%s: no body left at the wheel, the car is not one to jack (%d frames, "
			said += "kept %s, jackable %s)"
			K.check(
				fails,
				ok and not bool(r["jackable"]),
				said % [label, r["proxy_after"], r["driver_kept"], r["jackable"]]
			)
		"instant":
			K.check(
				fails,
				hit >= 0.0 and seat >= 0.0 and absf(seat - hit) < 0.2 and bool(r["victim_alive"]),
				"%s: the old instant take: blow and seat as one, driver put down" % label
			)
		"gone":
			K.check(
				fails,
				hit < 0.0 and seat >= 0.0,
				"%s: the old way: the ambient driver simply gone, no blow" % label
			)


## A row with a grab: the hands, the blow, the seat a while after, the driver put down, drawn.
func _judge_grab(label: String, r: Dictionary, want: String) -> void:
	var hit := float(r["hit_t"])
	var seat := float(r["seat_t"])
	var need := SEAT_GAP_S
	if want == "grab_doorless":
		need = SEAT_GAP_DOORLESS_S
	var said := "%s: the hands are on them %.2f s before the blow (%.1f), the blow at %.2f s, "
	said += "the seat %.2f s after it (%.1f)"
	var ok := hit >= 0.0 and float(r["grab_before"]) >= GRAB_MIN_S and seat >= 0.0
	K.check(
		fails,
		ok and seat - hit >= need,
		said % [label, r["grab_before"], GRAB_MIN_S, hit, seat - hit, need]
	)
	var sat := str(r["first_react"]) in ["sit", "sit_idle", "drag"]
	said = "%s: they are put down on the road, drawn in the sit pose as they came out (%s)"
	K.check(fails, bool(r["victim_alive"]) and sat, said % [label, r["first_react"]])
	K.check(
		fails,
		bool(r["drawn_at_grab"]),
		"%s: a body was drawn at the wheel as the hands closed on it" % label
	)
	said = "%s: both wrists are on the collar and the arm for %.2f s before the blow (%.2f)"
	K.check(fails, float(r["hands_on"]) >= HANDS_MIN_S, said % [label, r["hands_on"], HANDS_MIN_S])
	said = "%s: nobody is drawn at the wheel once the driver is on the road (%d frames)"
	K.check(fails, int(r["proxy_after"]) <= PROXY_MAX, said % [label, r["proxy_after"]])
	if label.begins_with("no sidewalk"):
		var down := ["sit", "sit_idle", "drag", "knockback", "get_up"]
		said = "%s: they get up and walk to the road's edge, not deleted (%s, %.2f m)"
		K.check(
			fails,
			str(r["end_react"]) not in down and float(r["walked_off"]) >= WALK_OFF_MIN,
			said % [label, r["end_react"], r["walked_off"]]
		)


## A row where nothing is taken: no blow, no seat, the driver stays, the car is let go (with the
## toast for a walk that failed twice, begun again once from where he stands, or a driver never
## drawn).
func _judge_refuse(label: String, r: Dictionary, want: String) -> void:
	var ok := float(r["hit_t"]) < 0.0 and float(r["seat_t"]) < 0.0 and bool(r["driver_kept"])
	ok = ok and not bool(r["held"]) and bool(r["on_foot"])
	if want == "refuse_late":
		ok = ok and bool(r["toast"])
	var said := "%s: nothing taken: no blow, no seat, driver stays, the car let go (kept %s, "
	said += "held %s, toast %s)"
	K.check(fails, ok, said % [label, r["driver_kept"], r["held"], r["toast"]])
	if want == "refuse_late" and label.begins_with("walk"):
		K.check(
			fails,
			int(r["fails"]) == 2 and int(r["tries"]) == 1,
			"%s: it was begun again once (%d fails, %d tries)" % [label, r["fails"], r["tries"]]
		)
