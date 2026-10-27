extends SceneTree
## Combat pose contracts: anatomical head limits after neck and clip rotations accumulate,
## directional and strength-scaled reactions, and a finisher's stagger before its fall.

const K := preload("res://tools/tests/fp_kit.gd")
const LOOK := preload("res://scripts/fp/player/hero_look.gd")
const KICK := preload("res://scripts/fp/player/hero_kick_pose.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_head()
	_check_kick()
	_check_directions()
	_check_strength()
	_check_finisher()
	_check_flag_off()
	FeatureFlags.reload()
	K.finish(self, "FP_COMBAT_POSE_TEST", fails)


## The final head, not each individual modifier, must stay inside the torso-relative limits.
func _check_head() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	holder.basis = Basis(Vector3.UP, 1.2).scaled(Vector3.ONE * WS.M)
	var sk := Skeleton3D.new()
	holder.add_child(sk)
	sk.add_bone("Neck")
	sk.add_bone("Head")
	sk.set_bone_parent(1, 0)
	for pitch: float in [-1.2, 1.2]:
		sk.set_bone_pose_rotation(0, Quaternion(Vector3.RIGHT, pitch))
		sk.set_bone_pose_rotation(1, Quaternion(Vector3.UP, 1.7))
		LOOK.clamp_head(sk, holder.global_basis, LOOK.LOOK_YAW, LOOK.HEAD_PITCH)
		var local := (
			holder.global_basis.inverse() * (sk.global_basis * sk.get_bone_global_pose(1).basis.z)
		)
		var angles := _angles(local)
		K.check(
			fails,
			absf(angles.x) <= LOOK.LOOK_YAW + 0.001 and absf(angles.y) <= LOOK.HEAD_PITCH + 0.001,
			(
				"the completed head respects yaw and pitch (%.1f, %.1f deg)"
				% [rad_to_deg(angles.x), rad_to_deg(angles.y)]
			)
		)
		LOOK.clamp_head(sk, holder.global_basis, LOOK.COMBAT_YAW, LOOK.COMBAT_PITCH)
		local = (
			holder.global_basis.inverse() * (sk.global_basis * sk.get_bone_global_pose(1).basis.z)
		)
		angles = _angles(local)
		K.check(
			fails,
			(
				absf(angles.y) <= LOOK.COMBAT_PITCH + 0.001
				and absf(angles.x) <= LOOK.COMBAT_YAW + 0.001
			),
			"combat keeps the chin down (%.1f deg pitch)" % rad_to_deg(angles.y)
		)
	holder.free()


func _angles(dir: Vector3) -> Vector2:
	return Vector2(atan2(dir.x, dir.z), atan2(dir.y, Vector2(dir.x, dir.z).length()))


## The kick raises a folded leg first and folds it again before the foot returns to the ground.
func _check_kick() -> void:
	var c := 0.24
	var chamber := KICK.foot(c * 0.5, c)
	var contact := KICK.foot(c, c)
	var recoil := KICK.foot(c + KICK.RECOIL_S, c)
	var planted := KICK.foot(c + KICK.PLANT_S, c)
	K.check(fails, chamber.y > 0.5 and chamber.z < 0.35, "the kick chambers with the knee bent")
	K.check(fails, contact.z > 0.8 and contact.y > 0.75, "the foot extends at contact")
	K.check(fails, recoil.distance_to(chamber) < 0.001, "the kick recoils into its chamber")
	K.check(fails, planted.distance_to(KICK.REST) < 0.001, "the foot plants after recoil")
	K.check(
		fails,
		KICK.weight(c, c) == 1.0 and KICK.weight(c + KICK.PLANT_S + KICK.RELEASE_S, c) == 0.0,
		"the foot is owned through contact and released after planting"
	)


func _fixture() -> Dictionary:
	var wk := WK.new()
	var w := wk.make("ambient")
	wk.stand(w, Vector3.ZERO, 0.0)
	var re := RE.new()
	re.setup(wk, null, 12)
	re.fight_odds = {"punch": 0.0, "shove": 0.0}
	return {"w": w, "re": re}


## A body facing +Z leans toward the push without instantly spinning to face its source.
func _check_directions() -> void:
	FeatureFlags.set_override("directional_hits", true)
	FeatureFlags.set_override("hit_feel", true)
	for d: Vector3 in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var f := _fixture()
		var w: WK.Walker = f["w"]
		var re: RE = f["re"]
		re.hit(w, -d * WS.M, d, 0.5, "punch")
		for _k in 6:
			re.step(DT)
		var xf := WK.body_xf(w, 1.0, w.pos + w.vis_off)
		var lean := Vector3(xf.basis.y.x, 0.0, xf.basis.y.z)
		K.check(
			fails,
			is_zero_approx(w.yaw) and lean.dot(d) > 0.03,
			"a hit pushes the stagger %s without changing facing" % d
		)


func _check_strength() -> void:
	var amounts := []
	var durations := []
	for strength: float in [0.2, 0.65]:
		var f := _fixture()
		var w: WK.Walker = f["w"]
		var re: RE = f["re"]
		re.hit(w, Vector3.LEFT * WS.M, Vector3.RIGHT, strength, "punch")
		var r: RE.Reaction = re.get("_active")[w.id]
		amounts.append(r.tip)
		durations.append(r.tip_s)
	K.check(
		fails,
		amounts[1] > amounts[0] and durations[1] > durations[0],
		"a stronger light blow staggers further and longer"
	)


func _check_finisher() -> void:
	var f := _fixture()
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	re.hit(w, Vector3.LEFT * WS.M, Vector3.RIGHT, 0.85, "punch")
	K.check(fails, re.is_down(w) and w.react == &"hit_chest", "a finisher first staggers")
	re.step(0.06)
	K.check(fails, w.vis_off.y == 0.0 and w.vis_roll < 0.0, "the stagger leans before launching")
	for _k in 12:
		re.step(DT)
	K.check(fails, w.react == &"knockback" and w.vis_off.y > 0.0, "then the body falls and lifts")
	for cause: String in ["punch", "car"]:
		f = _fixture()
		w = f["w"]
		re = f["re"]
		re.hit(w, Vector3.LEFT * WS.M, Vector3.RIGHT, 0.85, cause, 3.0 if cause == "punch" else 0.0)
		re.step(DT)
		K.check(
			fails,
			w.react == &"knockback" and w.vis_off.y > 0.0,
			"%s launch stays immediate" % cause
		)


func _check_flag_off() -> void:
	FeatureFlags.set_override("directional_hits", false)
	var f := _fixture()
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	re.hit(w, Vector3.LEFT * WS.M, Vector3.RIGHT, 0.85, "punch")
	K.check(fails, w.react == &"knockback", "flag off retains the immediate fall")
	re.step(DT)
	K.check(fails, w.vis_roll == 0.0, "flag off never adds lateral lean")
