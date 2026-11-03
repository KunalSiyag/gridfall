extends RefCounted
## Where the hero's two hands take hold of the driver he pulls out of a car (carjack.gd grips, the
## hero's part in car_entry.gd): read per frame from the driver's own skeleton, so they follow the
## body as it leans, is drawn out of the seat and lands. The left hand goes for the collar (the
## surface of the upper chest below the neck, on the side toward the hero) and the right for the
## near upper arm, whichever of the two is on the hero's right taking the right hand; a driver sat
## so high that the collar is out of the hero's reach (a bus or truck cab) is held lower down the
## chest instead, never above what the hero can reach without raising his hands over his head.

const WS := preload("res://scripts/fp/world_scale.gd")
## The surface stands out from the bones' line by these shares of the hips-to-neck length (a body
## about 0.6 m long from the hips to the neck: 0.11 m at the chest, 0.05 m at the arm).
const CHEST_OUT := 0.18
const ARM_OUT := 0.08
## The collar rests this share of the way down from the neck bone to the upper chest's; the arm grip
## this share of the way down the upper arm.
const COLLAR_DOWN := 0.1
const ARM_DOWN := 0.15
## The bones whose points the hero keeps off (the "keep" of the result): the trunk, the arms and the
## legs, not the hands and the feet.
const KEEP_BONES := [
	"Head",
	"Neck",
	"UpperChest",
	"Spine",
	"Hips",
	"LeftShoulder",
	"RightShoulder",
	"LeftUpperArm",
	"RightUpperArm",
	"LeftLowerArm",
	"RightLowerArm",
	"LeftUpperLeg",
	"RightUpperLeg",
	"LeftLowerLeg",
	"RightLowerLeg"
]


## The two grip points {"collar", "arm"} (world; NAN each with no skeleton or no such bone) on the
## skeleton sk of the driver, for a hero standing at toward (world; only its direction in plan
## counts), neither above the height top (world y; INF for none). The arm is the one on `side`
## ("Left" or "Right"), the one nearer the hero when none is asked for; "side" in the result says
## which it was (the hold keeps to it: the nearer arm changes as the body turns over). "keep" is the
## points of the driver's trunk, arms and legs (KEEP_BONES): what the hero stands clear of.
static func points(
	sk: Skeleton3D, toward: Vector3, top: float = INF, side: String = ""
) -> Dictionary:
	var out := {
		"collar": Vector3(NAN, NAN, NAN),
		"arm": Vector3(NAN, NAN, NAN),
		"side": side,
		"keep": PackedVector3Array()
	}
	if sk == null or not sk.is_inside_tree():
		return out
	var keep := PackedVector3Array()
	for bn: String in KEEP_BONES:
		var q := _bone(sk, bn)
		if q.is_finite():
			keep.append(q)
	out["keep"] = keep
	var hips := _bone(sk, "Hips")
	var neck := _bone(sk, "Neck")
	var chest := _bone(sk, "UpperChest")
	if not neck.is_finite() or not hips.is_finite():
		return out
	if not chest.is_finite():
		chest = hips.lerp(neck, 0.8)
	var span := hips.distance_to(neck)
	var core := neck.lerp(chest, COLLAR_DOWN)
	var collar := core + _to(core, toward) * span * CHEST_OUT
	out["collar"] = _under(collar, hips, chest, top)
	var found := _arm(sk, toward, side)
	var arm: Vector3 = found[0]
	if arm.is_finite():
		out["arm"] = _under(arm + _to(arm, toward) * span * ARM_OUT, hips, chest, top)
		out["side"] = found[1]
	return out


## The hand each of the two grips goes to given the hero's right (a level unit vector): the one
## that is on his right goes to his right hand. [left hand's point, right hand's point].
static func hands(grips: Dictionary, right: Vector3) -> PackedVector3Array:
	var a: Vector3 = grips["collar"]
	var b: Vector3 = grips["arm"]
	if not b.is_finite():
		return PackedVector3Array([a, a])
	if b.dot(right) >= a.dot(right):
		return PackedVector3Array([a, b])
	return PackedVector3Array([b, a])


## The point on the upper arm nearest the hero (world): the arm whose shoulder is nearer to him.
static func _arm(sk: Skeleton3D, toward: Vector3, want: String) -> Array:
	var best := Vector3(NAN, NAN, NAN)
	var which := ""
	var bd := INF
	for side: String in ["Left", "Right"] if want.is_empty() else [want]:
		var top := _bone(sk, side + "UpperArm")
		var low := _bone(sk, side + "LowerArm")
		if not top.is_finite() or not low.is_finite():
			continue
		var p := top.lerp(low, ARM_DOWN)
		var d := Vector2(p.x - toward.x, p.z - toward.z).length()
		if d < bd:
			bd = d
			best = p
			which = side
	return [best, which]


## p lowered to no higher than top, but not below the belt (a hand's breadth over the hips).
static func _under(p: Vector3, hips: Vector3, chest: Vector3, top: float) -> Vector3:
	if p.y <= top:
		return p
	var low := hips.lerp(chest, 0.15).y
	return Vector3(p.x, maxf(top, low), p.z)


## The unit vector in plan from p toward toward (zero when they coincide in plan).
static func _to(p: Vector3, toward: Vector3) -> Vector3:
	var d := Vector3(toward.x - p.x, 0.0, toward.z - p.z)
	return d.normalized() if d.length() > 1e-6 else Vector3.ZERO


static func _bone(sk: Skeleton3D, name: String) -> Vector3:
	var i := sk.find_bone(name)
	if i < 0:
		return Vector3(NAN, NAN, NAN)
	return sk.global_transform * sk.get_bone_global_pose(i).origin
