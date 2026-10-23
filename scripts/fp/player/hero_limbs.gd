extends RefCounted
## The hero's hands and feet on holds (slice A; hero_rig.gd, for the parkour feature's wall
## climb): a TwoBoneIK3D a limb (upper arm, forearm and hand; thigh, shin and foot) reaches the
## end bone for a target with the elbow or knee bent toward a pole, both top-level Marker3Ds placed
## in world space. Each limb's influence eases toward its goal weight, and a limb let go is
## switched off. The IK runs in the skeleton's own update, after the AnimationTree has posed it.

const SM := preload("res://scripts/fp/player/spring_math.gd")

## Left hand, right hand, left foot, right foot: (root, middle, end) bones.
const CHAINS := [
	["LeftUpperArm", "LeftLowerArm", "LeftHand"],
	["RightUpperArm", "RightLowerArm", "RightHand"],
	["LeftUpperLeg", "LeftLowerLeg", "LeftFoot"],
	["RightUpperLeg", "RightLowerLeg", "RightFoot"],
]
## The influences follow their goals with this halflife (s); a limb let go is off below OFF.
const HL_WEIGHT := 0.06
const OFF := 0.005

var iks: Array[TwoBoneIK3D] = []
var targets: Array[Marker3D] = []
var poles: Array[Marker3D] = []
## Each limb's influence (0..1).
var weights: PackedFloat32Array = PackedFloat32Array()
## Each end bone's world position after the IK, from the last frame it ran on that limb (tests).
var ends: Array[Vector3] = []
var _goals: PackedFloat32Array = PackedFloat32Array()
var _skeleton: Skeleton3D
var _end_bones: Array[int] = []


## Adds the modifiers under sk and the markers under holder (the body).
func _init(sk: Skeleton3D, holder: Node3D) -> void:
	_skeleton = sk
	for i in range(CHAINS.size()):
		var c: Array = CHAINS[i]
		var ik := TwoBoneIK3D.new()
		ik.name = "%sIK" % c[2]
		sk.add_child(ik)
		ik.setting_count = 1
		ik.set_root_bone_name(0, c[0])
		ik.set_middle_bone_name(0, c[1])
		ik.set_end_bone_name(0, c[2])
		targets.append(_marker(holder, "%sTarget" % c[2]))
		poles.append(_marker(holder, "%sPole" % c[2]))
		ik.set_target_node(0, ik.get_path_to(targets[i]))
		ik.set_pole_node(0, ik.get_path_to(poles[i]))
		ik.modification_processed.connect(_on_processed.bind(i))
		iks.append(ik)
		_end_bones.append(sk.find_bone(c[2]))
		weights.append(0.0)
		_goals.append(0.0)
		ends.append(Vector3.ZERO)
	_apply()


## Limb i (0 left hand, 1 right hand, 2 left foot, 3 right foot) reaches for target with its
## elbow or knee toward pole (world points), weight (0..1) of the way once eased in.
func set_goal(i: int, target: Vector3, pole: Vector3, weight: float) -> void:
	_goals[i] = clampf(weight, 0.0, 1.0)
	_place(targets[i], target)
	_place(poles[i], pole)


## Lets every limb go back to the clip, eased out or at once.
func release(at_once: bool = false) -> void:
	for i in range(_goals.size()):
		_goals[i] = 0.0
		if at_once:
			weights[i] = 0.0
	_apply()


## True while any limb follows its target.
func active() -> bool:
	for w: float in weights:
		if w > 0.0:
			return true
	return false


## Per frame: eases each limb's influence toward its goal.
func update(dt: float) -> void:
	for i in range(weights.size()):
		var w := _goals[i] if dt <= 0.0 else SM.damp(weights[i], _goals[i], HL_WEIGHT, dt)
		weights[i] = 0.0 if w < OFF and _goals[i] <= 0.0 else w
	_apply()


func _apply() -> void:
	for i in range(iks.size()):
		iks[i].influence = weights[i]
		iks[i].active = weights[i] > 0.0


func _on_processed(i: int) -> void:
	ends[i] = _skeleton.global_transform * _skeleton.get_bone_global_pose(_end_bones[i]).origin


static func _marker(holder: Node3D, n: String) -> Marker3D:
	var m := Marker3D.new()
	m.name = n
	m.top_level = true
	holder.add_child(m)
	return m


static func _place(m: Marker3D, p: Vector3) -> void:
	if m.is_inside_tree():
		m.global_position = p
	else:
		m.position = p
