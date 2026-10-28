extends RefCounted
## The backhoe loader's arm rig, for drive_feature.gd. The full model carries the loader arm and
## bucket as their own nodes (vehicles2.py's rig_part: Arm_Boom hinged at the chassis mount,
## Arm_Bucket at the boom's far end), so at the wheel of the yellow machine Y / U raise and lower
## the arm and I / O curl and tip the bucket (the backhoe_arm flag). The angles ease while the
## keys are held and hold once let go, the bucket swinging with the boom about its own hinge; a
## car without the nodes (every other model) leaves the rig idle. A dig over a construction site
## — the bucket tipped out with O, then curled back in with I with the arm low — grows a dirt
## pile in front of the machine, which stays once the hero drives off and starts again wherever
## the next dig happens to be.

const WS := preload("res://scripts/fp/world_scale.gd")

## The nodes the rig is found by, and the cache of them on the car's node (found once per car).
const BOOM_NODE := "Arm_Boom"
const BUCKET_NODE := "Arm_Bucket"
const RIG_META := "backhoe_arm_rig"
## The arm swings and the bucket curls at these rates (rad/s): a full sweep in ~4 s and ~2 s.
const BOOM_RATE := deg_to_rad(14.0)
const BUCKET_RATE := deg_to_rad(38.0)
## The arm hangs from just under level (folded over the nose) to well up for hauling.
const BOOM_MIN := deg_to_rad(-2.0)
const BOOM_MAX := deg_to_rad(52.0)
## The bucket curls from tipped out under the arm (scooping) to tucked in (holding).
const BUCKET_MIN := deg_to_rad(-75.0)
const BUCKET_MAX := deg_to_rad(15.0)
## Curling the bucket in with the arm below this (the lip at the ground) digs, and only while the
## bucket still has room to curl and only over a construction site: tip it out with O first, then
## a curl of I is the scoop. The pile grows a level a second, up to PILE_MAX.
const DIG_BOOM := deg_to_rad(14.0)
const DIG_RATE := 1.0
const PILE_MAX := 6.0
## The dirt pile: a squat mound this wide at the base and this high when full (m).
const PILE_W := 1.4
const PILE_H := 0.55
## The dig spot sits at the bucket hinge, this far ahead of the car's centre (m, the model's
## loader geometry).
const HINGE_AHEAD := 2.2
## The work loop (the backhoe_work flag): the stages a parked site machine digs through.
const WORK_STAGES := ["clearing", "excavation", "grading"]
## One dig cycle's span (s): the arm down, a curled scoop, the haul up, the dump, the settle.
const WORK_CYCLE_S := 9.0
## A pose the work loop wrote carries this tag on the boom node, so a save keeps only the hero's
## own posing (save_dict skips tagged rigs, the hero's first step at the wheel clears the tag).
const WORK_META := "arm_work"
## A dig this far from where the pile stands starts it again at the new spot (m).
const PILE_MOVE := 3.0
## Dirt brown, rough.
const DIRT := Color(0.33, 0.22, 0.12)

## The boom and bucket angles (rad; positive raises the arm, curls the bucket in).
var boom: float = 0.0
var bucket: float = 0.0
## The pile's size so far, in dig levels (0 when there is none).
var pile: float = 0.0
## The rig at the wheel ({boom, bucket, parent, boom_rest, bucket_in_boom}), else {}.
var _rig: Dictionary = {}
## The pile it dug ({node, spot}), else {}.
var _dirt: Dictionary = {}
## Poses a save left to put back ([[slot tile, slot k, boom, bucket], ...]), applied once the
## load's frames have drawn the machines (apply_saved: at the load itself no car has its node).
var _saved_poses: Array = []
## The pile a save left to stand again ([x, y, z, levels]), else empty.
var _saved_pile: Array = []
## The work loop's own clock (s of stepped frames; like construction_kit's animate, so a replay
## at the same frames sees the same sweep).
var _work_t: float = 0.0


## Another car (or none): forget its rig; the pile it dug stays put, its nodes keeping their
## angles until the next backhoe picks them up from the node metas.
func reset() -> void:
	_rig = {}


## The world going: forget the rig and take the pile with it (its nodes are freed with the
## scene), and drop whatever a save had left to put back (a load re-fills this from its own save
## after the rebuild).
func clear() -> void:
	reset()
	var n: Node = _dirt.get("node")
	if n != null and is_instance_valid(n):
		n.queue_free()
	_dirt = {}
	pile = 0.0
	_saved_poses.clear()
	_saved_pile.clear()


## True when the car carries the rig (the backhoe's own model), for the key hint on getting in.
func at_wheel(traffic: FpFeature, car_id: int) -> bool:
	return not _rig_for(traffic, car_id).is_empty()


## True while the car at the wheel carries the rig (found by its last step).
func rigged() -> bool:
	return not _rig.is_empty()


## The drive feature's save: the rigs the hero has posed -- each found again on the load by the
## curb slot its machine came from, which the deterministic parking fill re-fills -- and the
## pile where it stands, wrapped under "backhoe", or {} with nothing posed and no pile.
func save_dict(traffic: FpFeature) -> Dictionary:
	var out := {"poses": []}
	var vh: Variant = traffic.get("vehicles") if traffic != null else null
	if vh is Object:
		for c: Variant in (vh as Object).get("cars"):
			var node: Node3D = c.get("node") if c is Object else null
			if not is_instance_valid(node) or not node.has_meta(RIG_META):
				continue
			var rig: Dictionary = node.get_meta(RIG_META)
			if rig.is_empty() or int(c.get("home_tile")) < 0:
				continue
			if (rig["boom"] as Node3D).has_meta(WORK_META):
				continue  # the work loop's own posing is never saved
			var p_boom := float((rig["boom"] as Node3D).get_meta("arm_boom", 0.0))
			var p_bucket := float((rig["bucket"] as Node3D).get_meta("arm_bucket", 0.0))
			if is_zero_approx(p_boom) and is_zero_approx(p_bucket):
				continue
			out["poses"].append([int(c.get("home_tile")), int(c.get("home_k")), p_boom, p_bucket])
	if pile > 0.0 and is_instance_valid(_dirt.get("node")):
		var s: Vector3 = _dirt["spot"]
		out["pile"] = [s.x, s.y, s.z, pile]
	if (out["poses"] as Array).is_empty() and not out.has("pile"):
		return {}
	return {"backhoe": out}


## The save's "backhoe" half: the poses wait for their machines and the pile for a drawn car's
## parent, all put back by apply_saved once the load's frames have drawn them.
func from_dict(d: Variant) -> void:
	_saved_poses.clear()
	_saved_pile.clear()
	var b: Dictionary = d if typeof(d) == TYPE_DICTIONARY else {}
	var poses: Variant = b.get("poses", [])
	if typeof(poses) == TYPE_ARRAY:
		for e: Variant in poses:
			if typeof(e) == TYPE_ARRAY and (e as Array).size() >= 4:
				_saved_poses.append([int(e[0]), int(e[1]), float(e[2]), float(e[3])])
	var pl: Variant = b.get("pile", [])
	if typeof(pl) == TYPE_ARRAY and (pl as Array).size() >= 4:
		_saved_pile = [float(pl[0]), float(pl[1]), float(pl[2]), float(pl[3])]


## Puts back what a save left, once the load's frames have drawn the world: each posed backhoe
## is found by the curb slot its machine came from (a machine parks there again) and posed, the
## pile standing where it stood -- its level kept, so a dig left half-done goes on from there.
## Nothing to do once all is back.
func apply_saved(traffic: FpFeature) -> void:
	if _saved_poses.is_empty() and _saved_pile.is_empty():
		return
	var vh: Variant = traffic.get("vehicles") if traffic != null else null
	if not (vh is Object):
		return
	var parent: Node3D = null
	for c: Variant in (vh as Object).get("cars"):
		var n: Node3D = c.get("node") if c is Object else null
		if is_instance_valid(n):
			parent = n.get_parent()
			break
	if not _saved_pile.is_empty() and not is_instance_valid(_dirt.get("node")) and parent != null:
		var s := Vector3(_saved_pile[0], _saved_pile[1], _saved_pile[2])
		var n := _new_pile(parent)
		_dirt = {"node": n, "spot": s}
		pile = _saved_pile[3]
		_size_pile(n, s, s.y)
	for e: Array in _saved_poses.duplicate():
		var found: Variant = null
		for x: Variant in (vh as Object).get("cars"):
			if (
				x is Object
				and bool(x.get("parked"))
				and int(x.get("slot_tile")) == int(e[0])
				and int(x.get("slot_k")) == int(e[1])
			):
				found = x
				break
		var node: Node3D = found.get("node") if found is Object else null
		if not is_instance_valid(node):
			continue
		var rig := _rig_on(node)
		_saved_poses.erase(e)
		if not rig.is_empty():
			_pose(rig, float(e[2]), float(e[3]))


## One step at the wheel of car car_id at pos turned along heading (its centre, on the ground):
## the keys ease the arm and bucket, and a dig at a site grows the pile. Nothing to do without the
## rig (any other car).
func step(
	ctx: FpContext, traffic: FpFeature, car_id: int, pos: Vector3, heading: Vector2, dt: float
) -> void:
	if dt <= 0.0 or (_rig.is_empty() and _rig_for(traffic, car_id).is_empty()):
		return
	boom = move_toward(
		boom,
		(
			BOOM_MIN
			if Input.get_action_strength("backhoe_arm_down") > 0.5
			else (BOOM_MAX if Input.get_action_strength("backhoe_arm_up") > 0.5 else boom)
		),
		BOOM_RATE * dt
	)
	bucket = move_toward(
		bucket,
		(
			BUCKET_MIN
			if Input.get_action_strength("backhoe_bucket_dump") > 0.5
			else (BUCKET_MAX if Input.get_action_strength("backhoe_bucket_curl") > 0.5 else bucket)
		),
		BUCKET_RATE * dt
	)
	_apply()
	if not _rig.is_empty() and (_rig["boom"] as Node3D).has_meta(WORK_META):
		# The hero's own posing now: the arm is theirs, the save may keep it.
		(_rig["boom"] as Node3D).remove_meta(WORK_META)
	var spot := pos + Vector3(heading.x, 0.0, heading.y) * HINGE_AHEAD * WS.M
	var ground := _dig_ground(ctx, spot)
	if (
		Input.get_action_strength("backhoe_bucket_curl") > 0.5
		and boom < DIG_BOOM
		and bucket < BUCKET_MAX - 0.01
		and not is_nan(ground)
	):
		_grow(spot, ground, dt)


## The rig of the car (found once, then cached on its node), else {} (any other car). The angles
## ride on the nodes as metas, so a backhoe left with its arm up stays that way.
func _rig_for(traffic: FpFeature, car_id: int) -> Dictionary:
	if not _rig.is_empty():
		return _rig
	if traffic == null or car_id < 0:
		return {}
	var vh: Variant = traffic.get("vehicles")
	if not (vh is Object):
		return {}
	var c: Variant = (vh as Object).get("by_id").get(car_id)
	if c == null:
		return {}
	var node: Node3D = (c as Object).get("node") as Node3D
	if node == null:
		return {}
	if node.has_meta(RIG_META):
		_rig = node.get_meta(RIG_META)
	else:
		_rig = _rig_on(node)
		node.set_meta(RIG_META, _rig)
	if not _rig.is_empty():
		boom = float((_rig["boom"] as Node3D).get_meta("arm_boom", 0.0))
		bucket = float((_rig["bucket"] as Node3D).get_meta("arm_bucket", 0.0))
	return _rig


## The rig on a car's node, by the node's own children: the boom and bucket nodes with the
## bucket's hinge in the boom's rest frame, else {} (any other model). The rig_part objects ship
## with identity bases at their pivots, so the rest is the pivot alone and a turn is a pitch
## about the node's own X. The pile joins the car's own parent (the container the cars live in):
## it stands in the world, not on the machine.
func _rig_on(node: Node3D) -> Dictionary:
	var b := node.find_child(BOOM_NODE, true, false) as Node3D
	var k := node.find_child(BUCKET_NODE, true, false) as Node3D
	if b == null or k == null or b.get_parent() == null:
		return {}
	return {
		"boom": b,
		"bucket": k,
		"parent": node.get_parent(),
		"boom_rest": Transform3D(Basis.IDENTITY, b.position),
		"bucket_in_boom":
		(
			Transform3D(Basis.IDENTITY, b.position).affine_inverse()
			* Transform3D(Basis.IDENTITY, k.position)
		),
	}


## Turns the hero's rig to the angles stepped in.
func _apply() -> void:
	_pose(_rig, boom, bucket)


## Turns a rig: the boom pitches about its hinge, the bucket about its own as it rides along; the
## angles also go on the nodes as metas, so they hold until the hero is back (a save reads them).
func _pose(rig: Dictionary, p_boom: float, p_bucket: float) -> void:
	var b: Node3D = rig["boom"]
	var k: Node3D = rig["bucket"]
	var turn := Transform3D(Basis(Vector3.RIGHT, -p_boom), Vector3.ZERO)
	b.transform = (rig["boom_rest"] as Transform3D) * turn
	k.global_transform = (
		(b.global_transform * (rig["bucket_in_boom"] as Transform3D))
		* Transform3D(Basis(Vector3.RIGHT, -p_bucket), Vector3.ZERO)
	)
	b.set_meta("arm_boom", p_boom)
	k.set_meta("arm_bucket", p_bucket)


## One frame of the site machines' work loop (the backhoe_work flag): every backhoe parked at a
## live construction site (traffic's site machines) digs its cycle while the site is clearing,
## excavating or grading. The hero's own machine never joins (a driven car is skipped), a machine
## the hero has posed stays theirs, and a site past the digging stages leaves its machine still.
## Nothing to do without the flag, the sim or a site machine.
func work_step(ctx: FpContext, traffic: FpFeature, dt: float) -> void:
	if not FeatureFlags.enabled("backhoe_work"):
		return
	if ctx == null or ctx.sim == null or traffic == null or dt <= 0.0:
		return
	_work_t += dt
	var machines: Dictionary = traffic.call("site_machines")
	if machines.is_empty():
		return
	var vh: Variant = traffic.get("vehicles")
	if not (vh is Object):
		return
	var by_id: Variant = (vh as Object).get("by_id")
	for sid: Variant in machines.keys():
		var c: Variant = (by_id as Dictionary).get(int(machines[sid]))
		if c == null or bool((c as Object).get("driven")):
			continue
		_work_machine(ctx, c, int(sid))


## One site's machine digs its cycle: the pose is a pure function of the loop clock and the
## site's phase (the site id, the day and the city seed hashed, so a replay sees the same sweep),
## written with the work tag. The hero's own posing (an untagged rig off the rest) is left alone.
func _work_machine(ctx: FpContext, c: Variant, sid: int) -> void:
	var node: Node3D = (c as Object).get("node") as Node3D
	if node == null:
		return
	var rig: Dictionary = node.get_meta(RIG_META) if node.has_meta(RIG_META) else _rig_on(node)
	if rig.is_empty():
		return
	node.set_meta(RIG_META, rig)
	if not _site_digging(ctx, sid):
		return
	var b: Node3D = rig["boom"]
	if not b.has_meta(WORK_META) and not is_zero_approx(float(b.get_meta("arm_boom", 0.0))):
		return  # posed by the hero: the loop never takes a machine back
	var phase := float(absi(hash(Vector3i(sid, ctx.sim.day, ctx.sim.city_seed))) % 1000) / 1000.0
	var p := fposmod(_work_t / WORK_CYCLE_S + phase, 1.0)
	_pose(rig, _work_boom(p), _work_bucket(p))
	b.set_meta(WORK_META, true)


## True while the site with id sid is in a digging stage (clearing, excavation, grading).
func _site_digging(ctx: FpContext, sid: int) -> bool:
	for s: Variant in ctx.sim.sites.values():
		if int((s as Dictionary).get("id", -1)) == sid:
			return ctx.sim.site_stage_name(s) in WORK_STAGES
	return false


## The 0..1 share of the cycle's segment [a, b] covered by p, eased at both ends.
static func _work_ramp(p: float, a: float, b: float) -> float:
	return smoothstep(a, b, p)


## The boom angle through the cycle (rad): carry, lower to the ground, hold for the scoop, haul
## up, hold for the dump, and settle back for the next pass.
static func _work_boom(p: float) -> float:
	var down := deg_to_rad(5.0)
	var carry := deg_to_rad(40.0)
	var up := deg_to_rad(45.0)
	if p < 0.20:
		return lerpf(carry, down, _work_ramp(p, 0.0, 0.20))
	if p < 0.40:
		return down
	if p < 0.65:
		return lerpf(down, up, _work_ramp(p, 0.40, 0.65))
	if p < 0.80:
		return up
	return lerpf(up, carry, _work_ramp(p, 0.80, 1.0))


## The bucket angle through the cycle (rad): tipped out as the arm drops, the curl is the scoop,
## held through the haul, tipped out at the top for the dump, curled home for the next pass.
static func _work_bucket(p: float) -> float:
	var out := deg_to_rad(-60.0)
	if p < 0.20:
		return lerpf(BUCKET_MAX, out, _work_ramp(p, 0.0, 0.20))
	if p < 0.40:
		return lerpf(out, BUCKET_MAX, _work_ramp(p, 0.20, 0.40))
	if p < 0.65:
		return BUCKET_MAX
	if p < 0.80:
		return lerpf(BUCKET_MAX, out, _work_ramp(p, 0.65, 0.80))
	return lerpf(out, BUCKET_MAX, _work_ramp(p, 0.80, 1.0))


## The ground height at the spot ahead while it is a construction site's ground (the pile grows
## only there), else NAN.
func _dig_ground(ctx: FpContext, spot: Vector3) -> float:
	if ctx.sim == null or ctx.collision == null:
		return NAN
	if not ctx.sim.sites.has(ctx.collision.tile_at(spot)):
		return NAN
	return ctx.collision.walk_height(spot)


## A dig: the pile grows at the spot, starting again when the dig moves away from where it stands.
func _grow(spot: Vector3, ground: float, dt: float) -> void:
	pile = clampf(pile + DIG_RATE * dt, 0.0, PILE_MAX)
	var n: MeshInstance3D = _dirt.get("node")
	if not is_instance_valid(n):
		if _rig.is_empty():
			return
		n = _new_pile(_rig["parent"])
		_dirt = {"node": n, "spot": spot}
	elif spot.distance_to(_dirt["spot"] as Vector3) > PILE_MOVE:
		_dirt["spot"] = spot
		pile = clampf(DIG_RATE * dt, 0.0, PILE_MAX)
	_size_pile(n, spot, ground)


## The pile mesh, a squat dirt mound parented beside the cars (not to one: it stays put).
func _new_pile(parent: Node3D) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = DIRT
	mat.roughness = 1.0
	mesh.material = mat
	var n := MeshInstance3D.new()
	n.name = "DirtPile"
	n.mesh = mesh
	parent.add_child(n)
	return n


## The pile at its size: wider and taller the more has been dug, its base on the ground.
func _size_pile(n: MeshInstance3D, spot: Vector3, ground: float) -> void:
	var k := clampf(pile / PILE_MAX, 0.0, 1.0)
	var w := (0.45 + 0.55 * k) * PILE_W * WS.M
	var h := (0.3 + 0.7 * k) * PILE_H * WS.M
	n.scale = Vector3(w, h, w)
	n.global_position = Vector3(spot.x, ground + h * 0.35, spot.z)
