extends SceneTree
## The third-person hero's feet on the ground (unit G1, flag ground_foot_fit): the two-bone leg
## solve and the shift rules as pure maths, then the real hero walking and sprinting over a kerb (up
## and down), a lot slab's edge and an apron on the grown city. The clips' own sole contact is a few
## centimetres off the bones' standing heights even on a flat floor (measured here first, per gait):
## with the fit no sole sinks deeper than that, with the fit off it sinks 4 cm or more (the bug);
## the legs keep their lengths; flat ground costs nothing (no pose is written); straddling a kerb
## both soles rest on their own surface; and the fit is off with the flag, in first person, while
## wading, carried, airborne, climbing, driving or knocked down.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FOOT := preload("res://scripts/fp/player/foot_fit.gd")
const GP := preload("res://scripts/fp/world/ground_profile.gd")
const DT := 1.0 / 60.0
const M := WS.M
const CM := 0.01 * WS.M
## A fitted sole may be this far (cm) deeper than on a flat floor in the same gait.
const SLACK := 0.5
const FOUR: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]

var fails: Array[String] = []
## How deep a sole reads on a flat floor (cm), walking and sprinting (measured by _check_flat).
var noise := {"walk": 3.0, "sprint": 5.0}


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("ground_profile", true)
	FeatureFlags.set_override("ground_foot_fit", true)
	_check_maths()
	_check_skeleton()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.view.set_fp_mode(true)
	ctx.view.flush_rebuild_queue()
	ctx.player.set_process(false)
	var p := ctx.player
	K.check(
		fails,
		p.avatar != null and p.avatar.is_animated() and p.avatar.foot_fit != null,
		"fixture: the animated hero has a foot fit"
	)
	if p.avatar.foot_fit != null and p.avatar.foot_fit.call("usable"):
		await _check_flat(ctx)
		await _check_kerb(ctx)
		await _check_lot_edge(ctx)
		await _check_apron(ctx)
		await _check_off(ctx)
	K.finish(self, "FP_FOOT_FIT_TEST", fails)


# ------------------------------------------------------------------ maths


func _check_maths() -> void:
	var h := Vector3(0, 1, 0)
	var l1 := 0.45
	var l2 := 0.43
	var pole := Vector3(0, 0, 1)
	var worst_len := 0.0
	var worst_pos := 0.0
	for t: Vector3 in [
		Vector3(0, 0.2, 0),
		Vector3(0.1, 0.35, 0.05),
		Vector3(-0.2, 0.3, -0.1),
		Vector3(0, 0.2, 0.3),
		Vector3(0.3, 0.5, 0)
	]:
		var sol := FOOT.two_bone(h, l1, l2, t, pole)
		var knee: Vector3 = sol[0]
		var ankle: Vector3 = sol[1]
		worst_len = maxf(
			worst_len, maxf(absf(h.distance_to(knee) - l1), absf(knee.distance_to(ankle) - l2))
		)
		worst_pos = maxf(worst_pos, ankle.distance_to(t))
		K.check(
			fails,
			knee.z >= (h.z + t.z) * 0.5 - 1e-6 or t.z > 0.2,
			"two_bone: the knee bends toward the pole (%s)" % str(knee)
		)
	K.check(
		fails,
		worst_len < 1e-5 and worst_pos < 1e-5,
		(
			"two_bone: bone lengths kept (%.6f) and the ankle on a reachable target (%.6f)"
			% [worst_len, worst_pos]
		)
	)
	var far := FOOT.two_bone(h, l1, l2, Vector3(0, -1.5, 0), pole)
	K.check(
		fails,
		absf(h.distance_to(far[1]) - (l1 + l2)) < 1e-4 and far[1].x == 0.0,
		"two_bone: a target out of reach stretches the leg straight toward it"
	)
	var near := FOOT.two_bone(h, l1, l2, h + Vector3(0.001, 0, 0), pole)
	K.check(
		fails,
		absf(h.distance_to(near[1]) - absf(l1 - l2)) < 1e-3,
		"two_bone: a target too close folds the leg"
	)
	K.check(
		fails,
		(
			FOOT.plant_weight(0.0) == 1.0
			and FOOT.plant_weight(FOOT.PLANT_NONE) == 0.0
			and FOOT.plant_weight(FOOT.LIFT_TOL) == 1.0
		),
		"plant_weight: planted up to LIFT_TOL, swing from PLANT_NONE"
	)
	# plan(offset, lift) = (follow, floor): a planted foot follows the ground, a sunk one is lifted.
	var up := FOOT.plan(0.12 * M, 0.0)
	var down := FOOT.plan(-0.12 * M, 0.0)
	K.check(
		fails,
		is_equal_approx(up.x, 0.12 * M) and is_equal_approx(up.y, 0.12 * M),
		"plan: a planted foot on a kerb 12 cm up goes up 12 cm (%s)" % str(up / CM)
	)
	K.check(
		fails,
		is_equal_approx(down.x, -0.12 * M) and is_equal_approx(down.y, -0.12 * M),
		"plan: a planted foot off a kerb goes down 12 cm, and no further (%s)" % str(down / CM)
	)
	var swing := FOOT.plan(0.12 * M, 0.2 * M)
	K.check(
		fails,
		swing.x == 0.0 and swing.y < 0.0,
		"plan: a swing foot 20 cm up clears a 12 cm kerb and is not moved (%s)" % str(swing / CM)
	)
	var low := FOOT.plan(0.12 * M, 0.08 * M)
	K.check(
		fails,
		low.x == 0.0 and is_equal_approx(low.y, 0.07 * M),
		(
			"plan: a swing foot 8 cm up is lifted the 7 cm it needs to clear the kerb (%s)"
			% str(low / CM)
		)
	)
	K.check(
		fails,
		FOOT.plan(0.002 * M, 0.0) == Vector2(0.0, 0.0) or FOOT.plan(0.002 * M, 0.0).x == 0.0,
		"plan: noise in the ground is not followed"
	)
	K.check(
		fails,
		(
			FOOT.plan(0.004 * M, 0.0).y == 0.0
			and FOOT.plan(0.0, 0.02 * M).y <= 0.0
			and FOOT.plan(0.0, 0.0).x == 0.0
		),
		"plan: a sink of a few mm and the clip's own contact hover do nothing"
	)


## A synthetic leg (hips, thigh, shin, foot): the solve puts the ankle on the target, keeps both
## bone lengths and the foot's own orientation.
func _check_skeleton() -> void:
	var sk := Skeleton3D.new()
	get_root().add_child(sk)
	for n: String in ["Hips", "UpperLeg", "LowerLeg", "Foot"]:
		sk.add_bone(n)
	sk.set_bone_parent(1, 0)
	sk.set_bone_parent(2, 1)
	sk.set_bone_parent(3, 2)
	sk.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0)))
	sk.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)))
	sk.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0, -0.45, 0.04)))
	sk.set_bone_rest(3, Transform3D(Basis.IDENTITY, Vector3(0, -0.43, -0.04)))
	sk.reset_bone_poses()
	var foot_q0 := sk.get_bone_global_pose(3).basis.get_rotation_quaternion()
	var ankle0 := sk.get_bone_global_pose(3).origin
	var worst := 0.0
	var lens := 0.0
	var spin := 0.0
	for dy: float in [0.0, 0.05, 0.1, 0.2]:
		sk.reset_bone_poses()
		var t := ankle0 + Vector3(0.0, dy, 0.0)
		FOOT.solve_leg(sk, 1, 2, 3, t)
		worst = maxf(worst, sk.get_bone_global_pose(3).origin.distance_to(t))
		lens = maxf(
			lens,
			maxf(
				absf(
					(
						sk.get_bone_global_pose(1).origin.distance_to(
							sk.get_bone_global_pose(2).origin
						)
						- sqrt(0.45 * 0.45 + 0.04 * 0.04)
					)
				),
				absf(
					(
						sk.get_bone_global_pose(2).origin.distance_to(
							sk.get_bone_global_pose(3).origin
						)
						- sqrt(0.43 * 0.43 + 0.04 * 0.04)
					)
				)
			)
		)
		spin = maxf(
			spin, sk.get_bone_global_pose(3).basis.get_rotation_quaternion().angle_to(foot_q0)
		)
	K.check(
		fails,
		worst < 1e-4 and lens < 1e-4 and spin < 1e-3,
		"solve_leg: ankle %.6f off, lengths %.6f, foot turn %.6f" % [worst, lens, spin]
	)
	sk.free()


# ------------------------------------------------------------------ the hero over steps


## A straight paved road tile with a clear line across its kerb: {"from": feet, "dir": unit toward
## the sidewalk, "yaw": degrees, "kerb": point on the kerb line}. The run is clear 0.3 tile either
## side along the road.
func _find_kerb(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	var col := ctx.collision
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER or not RoadTopology.paved(sim, i):
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		for side: float in [1.0, -1.0]:
			for along: float in [-0.25, 0.0, 0.25]:
				var dir := (
					Vector3(side, 0.0, 0.0) if m == RoadTopology.NS else Vector3(0.0, 0.0, side)
				)
				var run := (
					Vector3(0.0, 0.0, 1.0) if m == RoadTopology.NS else Vector3(1.0, 0.0, 0.0)
				)
				var c := Vector3(D.tx(i), 0.0, D.ty(i)) + run * along
				if _clear(col, c + dir * 0.12, c + dir * 0.46):
					return {
						"from": c + dir * 0.18,
						"dir": dir,
						"yaw": rad_to_deg(atan2(-dir.x, -dir.z)),
						"kerb": c + dir * WS.ROAD_HALF
					}
	return {}


## True when a hero-sized circle can stand at every 0.02 along the line a-b.
func _clear(col: CollisionWorld, a: Vector3, b: Vector3) -> bool:
	var n := int(a.distance_to(b) / 0.02)
	for k in range(n + 1):
		var q := a.lerp(b, float(k) / float(maxi(n, 1)))
		q.y = col.walk_height(q)
		if is_nan(q.y) or col.is_blocked(q, WS.PLAYER_RADIUS * 1.6):
			return false
	return true


## A built lot (zone or service) with open lawn on one side: {"from", "dir", "yaw", "kerb"} walking
## off the slab toward the lawn.
func _find_lot_edge(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	var col := ctx.collision
	for i in sim.active:
		if sim.kind[i] == D.ROAD or GP.slab_top(sim, i) != WS.LOT_TOP:
			continue
		for dv: Vector2i in FOUR:
			var x := D.tx(i) + dv.x
			var y := D.ty(i) + dv.y
			if (
				not D.in_bounds(x, y)
				or sim.kind[D.idx(x, y)] != D.EMPTY
				or sim.terrain[D.idx(x, y)] == D.WATER
			):
				continue
			var dir := Vector3(dv.x, 0.0, dv.y)
			var c := Vector3(D.tx(i), 0.0, D.ty(i))
			for along: float in [-0.3, 0.0, 0.3]:
				var side := Vector3(-dir.z, 0.0, dir.x) * along
				if _clear(col, c + side + dir * 0.38, c + side + dir * 0.7):
					return {
						"from": c + side + dir * 0.38,
						"dir": dir,
						"yaw": rad_to_deg(atan2(-dir.x, -dir.z)),
						"kerb": c + side + dir * GP.LOT_HALF
					}
	return {}


## A built lot with an apron toward a road: the walk off the slab across the apron and onto the
## sidewalk.
func _find_apron(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	var col := ctx.collision
	for i in sim.active:
		if sim.kind[i] == D.ROAD or GP.slab_top(sim, i) != WS.LOT_TOP:
			continue
		var mask := GP.apron_mask(sim, i, ctx.directory.frontage(i))
		for s in range(4):
			if not (mask & (1 << s)):
				continue
			var dir := Vector3(GP.SIDES[s].x, 0.0, GP.SIDES[s].y)
			var c := Vector3(D.tx(i), 0.0, D.ty(i))
			for along: float in [-0.3, 0.0, 0.3]:
				var side := Vector3(-dir.z, 0.0, dir.x) * along
				if _clear(col, c + side + dir * 0.4, c + side + dir * 0.66):
					return {
						"from": c + side + dir * 0.4,
						"dir": dir,
						"yaw": rad_to_deg(atan2(-dir.x, -dir.z)),
						"kerb": c + side + dir * GP.APRON_FROM
					}
	return {}


## Walks the hero from `from` along dir for `frames` frames at WALK or SPRINT, recording the
## sole gaps: {"pen": the most any sole sank (cm, positive), "hover": the highest a sole hung
## above the ground (cm), "legs": the largest change of a leg's length (mm), "solves": poses
## written, "pelvis": the lowest pelvis drop (cm, positive)}.
func _walk(
	ctx: FpContext, from: Vector3, yaw: float, frames: int, sprint: bool = false
) -> Dictionary:
	var p := ctx.player
	var av := p.avatar
	var fit: RefCounted = av.foot_fit
	var rig: RefCounted = av.rig
	p.teleport(from, yaw)
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT)
		p.update_view(DT)
	var solves0: int = fit.solves
	var out := {"pen": 0.0, "hover": 0.0, "legs": 0.0, "solves": 0, "pelvis": 0.0}
	var sk: Skeleton3D = rig.get("skeleton")
	var len0 := _leg_lengths(sk)
	for k in range(frames):
		p.simulate(Vector2(0, 1), sprint, DT)
		p.update_view(DT)
		var gaps: Vector2 = fit.sole_gaps(av.foot_fit_ground, av.global_position.y)
		out["pen"] = maxf(float(out["pen"]), -minf(gaps.x, gaps.y) / CM)
		out["hover"] = maxf(float(out["hover"]), maxf(gaps.x, gaps.y) / CM)
		out["pelvis"] = maxf(float(out["pelvis"]), -float(fit.pelvis) / CM)
		var now := _leg_lengths(sk)
		for q in range(now.size()):
			out["legs"] = maxf(float(out["legs"]), absf(now[q] - len0[q]) / M * 1000.0)
	out["solves"] = int(fit.solves) - solves0
	return out


## The four bone lengths of both legs (skeleton metres scaled to world units).
func _leg_lengths(sk: Skeleton3D) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var k := sk.global_transform.basis.y.length()
	for leg: Array in FOOT.LEGS:
		var pts: Array[Vector3] = []
		for n: String in leg.slice(0, 3):
			pts.append(sk.get_bone_global_pose(sk.find_bone(n)).origin)
		out.append(pts[0].distance_to(pts[1]) * k)
		out.append(pts[1].distance_to(pts[2]) * k)
	return out


func _check_kerb(ctx: FpContext) -> void:
	var spot := _find_kerb(ctx)
	K.check(fails, not spot.is_empty(), "fixture: a clear kerb crossing")
	if spot.is_empty():
		return
	var from: Vector3 = spot["from"]
	var yaw: float = spot["yaw"]
	var back_from: Vector3 = (spot["kerb"] as Vector3) + (spot["dir"] as Vector3) * 0.18
	var back_yaw := yaw + 180.0
	for sprint in [false, true]:
		var label := "sprint" if sprint else "walk"
		var frames := 120 if sprint else 240
		FeatureFlags.set_override("ground_foot_fit", true)
		var up := await _walk_logged(ctx, from, yaw, frames, sprint)
		var down := await _walk_logged(ctx, back_from, back_yaw, frames, sprint)
		FeatureFlags.set_override("ground_foot_fit", false)
		var up_off := await _walk_logged(ctx, from, yaw, frames, sprint)
		var down_off := await _walk_logged(ctx, back_from, back_yaw, frames, sprint)
		FeatureFlags.set_override("ground_foot_fit", true)
		K.check(
			fails,
			(
				float(up["pen"]) <= float(noise["sprint" if sprint else "walk"]) + SLACK
				and float(down["pen"]) <= float(noise["sprint" if sprint else "walk"]) + SLACK
			),
			(
				"kerb %s: fit keeps soles out (flat %.2f cm + %.1f; up %.2f, down %.2f)"
				% [
					label,
					float(noise["sprint" if sprint else "walk"]),
					SLACK,
					float(up["pen"]),
					float(down["pen"])
				]
			)
		)
		K.check(
			fails,
			float(up_off["pen"]) >= 4.0 or float(down_off["pen"]) >= 4.0,
			(
				"kerb %s: without the fit soles sink (up %.2f cm, down %.2f cm)"
				% [label, float(up_off["pen"]), float(down_off["pen"])]
			)
		)
		K.check(
			fails,
			float(up["legs"]) < 1.5 and float(down["legs"]) < 1.5,
			(
				"kerb %s: the legs keep their lengths (%.2f / %.2f mm change)"
				% [label, float(up["legs"]), float(down["legs"])]
			)
		)
		K.check(
			fails,
			int(up["solves"]) > 0 and int(down["solves"]) > 0,
			(
				"kerb %s: the fit worked (%d + %d poses written)"
				% [label, int(up["solves"]), int(down["solves"])]
			)
		)
		K.check(
			fails,
			float(up["pelvis"]) <= 22.0 * 1.001 and float(down["pelvis"]) <= 22.0 * 1.001,
			(
				"kerb %s: the pelvis never drops more than 22 cm (%.1f / %.1f)"
				% [label, float(up["pelvis"]), float(down["pelvis"])]
			)
		)
	# Standing straddled on the kerb line: the foot over the road comes down, the other stays up.
	var kerb: Vector3 = spot["kerb"]
	var stand := await _walk_logged(ctx, kerb + (spot["dir"] as Vector3) * 0.004, yaw + 90.0, 1)
	var dbg_fit: RefCounted = ctx.player.avatar.foot_fit
	var dbg_g: Vector2 = dbg_fit.sole_gaps(
		ctx.player.avatar.foot_fit_ground, ctx.player.avatar.global_position.y
	)
	print(
		"  note straddle: sole gaps (cm) ",
		dbg_g / CM,
		" foot shifts (cm) ",
		(dbg_fit.shifts as Vector2) / CM,
		" pelvis ",
		float(dbg_fit.pelvis) / CM
	)
	K.check(
		fails,
		(
			float(stand["pen"]) <= float(noise["walk"]) + SLACK
			and float(stand["hover"]) <= float(noise["walk"]) + SLACK
		),
		(
			"straddling the kerb: soles on the surface (sink %.2f cm, hover %.2f cm)"
			% [float(stand["pen"]), float(stand["hover"])]
		)
	)
	print(
		(
			"  note kerb: the fit's worst pelvis drop %.1f cm; sprint legs change %.2f mm"
			% [float(stand["pelvis"]), float(stand["legs"])]
		)
	)
	await _check_heel(ctx, spot)


## Standing across the kerb line facing the road, so the heel is on the sidewalk and the ankle and
## the tip are over the road: every position of the line from 4 cm either side of the origin, the
## sole sampled at heel, ball and tip. The fit looks at the heel too, so the foot stands on the
## lip and the heel does not sink into it (a fit that looked at the ankle and the tip only left
## the heel 10 cm or more in the sidewalk at some of these places).
func _check_heel(ctx: FpContext, spot: Dictionary) -> void:
	var kerb: Vector3 = spot["kerb"]
	var dir: Vector3 = spot["dir"]
	var yaw: float = float(spot["yaw"]) + 180.0
	var worst_on := 0.0
	var worst_off := 0.0
	for off_cm in range(-4, 11, 1):
		var at := kerb + dir * (float(off_cm) * CM)
		FeatureFlags.set_override("ground_foot_fit", true)
		var on := await _walk_logged(ctx, at, yaw, 1)
		worst_on = maxf(worst_on, float(on["pen"]))
		FeatureFlags.set_override("ground_foot_fit", false)
		var off := await _walk_logged(ctx, at, yaw, 1)
		worst_off = maxf(worst_off, float(off["pen"]))
	FeatureFlags.set_override("ground_foot_fit", true)
	K.check(
		fails,
		worst_on <= float(noise["walk"]) + SLACK,
		(
			"kerb, heel on the lip: no sole sinks more than %.2f + %.1f cm (%.2f; %.2f unfitted)"
			% [float(noise["walk"]), SLACK, worst_on, worst_off]
		)
	)


func _walk_logged(
	ctx: FpContext, from: Vector3, yaw: float, frames: int, sprint: bool = false
) -> Dictionary:
	var r := _walk(ctx, from, yaw, frames, sprint)
	await process_frame
	return r


func _check_lot_edge(ctx: FpContext) -> void:
	var spot := _find_lot_edge(ctx)
	K.check(fails, not spot.is_empty(), "fixture: a clear lot slab edge onto lawn")
	if spot.is_empty():
		return
	var from: Vector3 = spot["from"]
	var yaw: float = spot["yaw"]
	var back_from: Vector3 = (spot["kerb"] as Vector3) + (spot["dir"] as Vector3) * 0.25
	FeatureFlags.set_override("ground_foot_fit", true)
	var off_slab := await _walk_logged(ctx, from, yaw, 200)
	var onto_slab := await _walk_logged(ctx, back_from, yaw + 180.0, 200)
	FeatureFlags.set_override("ground_foot_fit", false)
	var off_slab_off := await _walk_logged(ctx, from, yaw, 200)
	var onto_slab_off := await _walk_logged(ctx, back_from, yaw + 180.0, 200)
	FeatureFlags.set_override("ground_foot_fit", true)
	K.check(
		fails,
		(
			float(off_slab["pen"]) <= float(noise["walk"]) + SLACK
			and float(onto_slab["pen"]) <= float(noise["walk"]) + SLACK
		),
		(
			"lot edge: fit keeps soles out (flat %.2f cm + %.1f; off %.2f, on %.2f)"
			% [float(noise["walk"]), SLACK, float(off_slab["pen"]), float(onto_slab["pen"])]
		)
	)
	K.check(
		fails,
		float(off_slab_off["pen"]) >= 4.0 or float(onto_slab_off["pen"]) >= 4.0,
		(
			"lot slab edge: without it a sole sinks (%.2f / %.2f cm)"
			% [float(off_slab_off["pen"]), float(onto_slab_off["pen"])]
		)
	)


func _check_apron(ctx: FpContext) -> void:
	var spot := _find_apron(ctx)
	K.check(fails, not spot.is_empty(), "fixture: a clear apron")
	if spot.is_empty():
		return
	FeatureFlags.set_override("ground_foot_fit", true)
	var on := await _walk_logged(ctx, spot["from"], spot["yaw"], 200)
	FeatureFlags.set_override("ground_foot_fit", false)
	var off := await _walk_logged(ctx, spot["from"], spot["yaw"], 200)
	FeatureFlags.set_override("ground_foot_fit", true)
	K.check(
		fails,
		float(on["pen"]) <= float(noise["walk"]) + SLACK,
		(
			"apron: with the fit no sole sinks more than on flat ground (%.2f cm) + %.1f (%.2f)"
			% [float(noise["walk"]), SLACK, float(on["pen"])]
		)
	)
	print(
		(
			"  note apron (10 cm over 60 cm): sink %.2f cm without the fit, %.2f with"
			% [float(off["pen"]), float(on["pen"])]
		)
	)


## Flat sidewalk: nothing is solved, nothing is written; and how deep a sole reads here, per gait.
func _check_flat(ctx: FpContext) -> void:
	var sw := K.sidewalk(ctx, 0.4 * 1.0)
	K.check(fails, not sw.is_empty(), "fixture: a clear flat sidewalk")
	if sw.is_empty():
		return
	var r := await _walk_logged(ctx, sw["pos"], sw["yaw"], 180, false)
	K.check(
		fails,
		int(r["solves"]) == 0,
		(
			"flat sidewalk: the fit writes no pose while walking (%d writes, worst pelvis %.2f cm)"
			% [int(r["solves"]), float(r["pelvis"])]
		)
	)
	var s := await _walk_logged(ctx, sw["pos"], sw["yaw"], 120, true)
	K.check(
		fails,
		int(s["solves"]) == 0,
		(
			"flat sidewalk: nor while sprinting (%d writes, worst pelvis %.2f cm)"
			% [int(s["solves"]), float(s["pelvis"])]
		)
	)
	noise["walk"] = float(r["pen"])
	noise["sprint"] = float(s["pen"])
	print(
		(
			"  note flat ground: sole reads %.2f cm into the floor walking, %.2f sprinting"
			% [float(r["pen"]), float(s["pen"])]
		)
	)


## Off: with the flag, in first person (the body is only a shadow), carried, in the air, wading, and
## in the rig's states that are not locomotion (a wall hold, the car seat, a knock-down).
func _check_off(ctx: FpContext) -> void:
	var spot := _find_kerb(ctx)
	if spot.is_empty():
		return
	var p := ctx.player
	var av := p.avatar
	var fit: RefCounted = av.foot_fit
	var rig: RefCounted = av.rig
	var kerb: Vector3 = spot["kerb"]
	var on_line: Vector3 = kerb + (spot["dir"] as Vector3) * 0.004
	var yaw: float = spot["yaw"] + 90.0
	# Reference: on, straddling.
	FeatureFlags.set_override("ground_foot_fit", true)
	_stand(p, on_line, yaw)
	K.check(
		fails,
		absf(float(fit.pelvis)) > 4.0 * CM and fit.shifts != Vector2.ZERO,
		"straddling the kerb the fit is working (pelvis %.1f cm)" % (float(fit.pelvis) / CM)
	)
	# The flag.
	FeatureFlags.set_override("ground_foot_fit", false)
	_stand(p, on_line, yaw, 90)
	K.check(
		fails,
		fit.shifts == Vector2.ZERO and float(fit.pelvis) == 0.0,
		"flag off: no shift, no pelvis drop"
	)
	FeatureFlags.set_override("ground_foot_fit", true)
	# Each state in turn: settle on (reference), switch the state on, expect the fit to die away.
	var cases := {
		"first person": func() -> void: p.set_camera_mode("first", false),
		"carried": func() -> void: p.carried = true,
		"airborne": func() -> void: p.grounded = false,
		"wading": func() -> void: p.wade_depth = 0.2 * M,
		"climbing": func() -> void: rig.call("hold_wall", true),
		"driving": func() -> void: rig.call("sit", true, true, true),
		"knocked down": func() -> void: rig.call("play_action", "knockdown", 1.5),
	}
	var undo := {
		"first person": func() -> void: p.set_camera_mode("third", false),
		"carried": func() -> void: p.carried = false,
		"airborne": func() -> void: p.grounded = true,
		"wading": func() -> void: p.wade_depth = 0.0,
		"climbing": func() -> void: rig.call("hold_wall", false, true),
		"driving": func() -> void: rig.call("sit", false, true, true),
		"knocked down": func() -> void: rig.call("snap", false),
	}
	for name: String in cases:
		_stand(p, on_line, yaw, 60)
		var before := absf(float(fit.pelvis))
		(cases[name] as Callable).call()
		for k in range(90):
			p.update_view(DT)
		var after := absf(float(fit.pelvis))
		var state := str(rig.call("state"))
		K.check(
			fails,
			before > 4.0 * CM and after < 0.5 * CM,
			(
				"off while %s (state %s): pelvis %.1f -> %.2f cm"
				% [name, state, before / CM, after / CM]
			)
		)
		(undo[name] as Callable).call()
		await process_frame
	print("  note: states the fit runs in: %s" % str(FOOT.STATES))


## Teleports the hero to `at` and lets the rig settle for `frames` frames.
func _stand(p: FpPlayer, at: Vector3, yaw: float, frames: int = 45) -> void:
	p.set_camera_mode("third", false)
	p.carried = false
	p.grounded = true
	p.wade_depth = 0.0
	p.teleport(at, yaw)
	for k in range(frames):
		p.simulate(Vector2.ZERO, false, DT)
		p.update_view(DT)
