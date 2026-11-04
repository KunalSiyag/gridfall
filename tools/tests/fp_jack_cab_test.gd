extends "res://tools/tests/fp_jack_kit.gd"
## The driver of a body with no door that opens (a bus, a delivery truck, a bicycle, a scooter) is
## lifted over its solid side, never drawn through it (jack_cab.gd, jack_pull.gd): the hero takes
## hold of them from the side (jack_hold.gd) and as the pull draws them out, every frame from the
## first of the haul to the sit-down on the road, the hips and the thighs are above the top of the
## side (SILL) wherever they are within SKIN_BAND of it, the body does not jump between frames
## (JUMP_MAX), and comes to rest on the road beside the vehicle, outside its side (REST_OUT) and not
## above the ground (REST_UP). The driver of a car, which has a door, is not lifted (a control row).

const JC := preload("res://scripts/fp/traffic/jack_cab.gd")
## A body is through the side when its hips or thighs are within SKIN_BAND (m) of it in x and under
## the sill by more than SILL_SLACK (m).
const SKIN_BAND := 0.12
const SILL_SLACK := 0.03
## No frame moves the hips further than JUMP_MAX m.
const JUMP_MAX := 0.1
## At rest the hips are at least REST_OUT m beyond the side and at most REST_UP m over the road.
const REST_OUT := 0.25
const REST_UP := 0.6
const RUN_S := 12.0
const BONES := ["Hips", "LeftUpperLeg", "RightUpperLeg"]
var landings := 0


func _init() -> void:
	if await _fixture():
		ctx.bus.person_landed.connect(func(_at: Vector3, _id: int) -> void: landings += 1)
		for how: String in ["bus", "truck", "bike", "scooter", "stopped"]:
			await _row(how)
	K.check(fails, ran.size() == 5, "every row ran (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_CAB_TEST", fails)


func _bone(w: WK.Walker, bone: String) -> Vector3:
	var sk: Skeleton3D = w.body.get("skel") if w != null and w.body != null else null
	var i := sk.find_bone(bone) if sk != null else -1
	if i < 0:
		return Vector3(NAN, NAN, NAN)
	return sk.global_transform * sk.get_bone_global_pose(i).origin


func _row(how: String) -> void:
	door_model = _model_by_key("sedan_blue")
	K.quiet_walkers(traffic)
	for f: String in ["car_doors", "carjack", "heavy_motors", "bike_ride", "scooters"]:
		FeatureFlags.set_override(f, true)
	var c := _stage(how)
	hits.clear()
	victim = null
	var kind := c.kind
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	var inv := xf.affine_inverse()
	var sill := float(JC.SILL[kind][0]) * WS.M if JC.SILL.has(kind) else 0.0
	var half_w := c.half_w
	var rec := {"started": false}
	_begin(how, c, rec)
	var through := 0
	var frames := 0
	var jump := 0.0
	var was := Vector3.INF
	var rest := Vector3.INF
	landings = 0
	var lifted := 0.0
	for _step in range(int(RUN_S / DT)):
		_frame()
		await process_frame
		if victim == null:
			continue
		var react := str(victim.react)
		if react == "get_up":
			break
		var hips := inv * _bone(victim, "Hips")
		if not hips.is_finite():
			continue
		frames += 1
		if was.is_finite():
			jump = maxf(jump, hips.distance_to(was))
		was = hips
		rest = hips
		if absf(hips.x - half_w) <= SKIN_BAND * WS.M:
			lifted = maxf(lifted, hips.y)
		for b: String in BONES:
			var q := inv * _bone(victim, b)
			if q.is_finite() and sill > 0.0:
				if absf(q.x - half_w) <= SKIN_BAND * WS.M and q.y < sill - SILL_SLACK * WS.M:
					through += 1
	var label := "%s (%s, side at %.2f m)" % [how, kind, sill / WS.M]
	K.check(
		fails,
		victim != null and frames > 30,
		"%s: the driver was pulled out (%d frames)" % [label, frames]
	)
	if sill > 0.0:
		var said := "%s: the hips and thighs are over the side whenever they are across it "
		said += "(%d frames under it, hips %.2f m up at it)"
		K.check(fails, through == 0, said % [label, through, lifted / WS.M])
	else:
		K.check(
			fails,
			lifted / WS.M < 1.5,
			"%s: a door that opens: not lifted (%.2f m)" % [label, lifted / WS.M]
		)
	K.check(
		fails,
		jump <= JUMP_MAX * WS.M,
		(
			"%s: the body never jumps (%.2f m between frames, at most %.2f)"
			% [label, jump / WS.M, JUMP_MAX]
		)
	)
	var out := (rest.x - half_w) / WS.M if rest.is_finite() else -9.0
	var up := rest.y / WS.M if rest.is_finite() else 9.0
	K.check(
		fails,
		out >= REST_OUT and up <= REST_UP and landings > 0,
		"%s: it comes to rest on the road beside it (%.2f m out, %.2f m up)" % [label, out, up]
	)
	_reset()
	ran.append(how)
