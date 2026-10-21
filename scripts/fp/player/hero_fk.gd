extends RefCounted
## Forward kinematics over a body's own clip keys, without a tree or a scene: where the last bone
## of a chain sits at a phase of one clip or of two clips blended (rotations slerped, positions
## lerped). HeroRig measures heel contacts, standing heights and strike times with it. The root
## stays at rest (the mixer extracts its motion); position keys scale by the skeleton's
## motion_scale, as the mixer applies them.

var skeleton: Skeleton3D
var _tracks: Dictionary = {}


func _init(sk: Skeleton3D) -> void:
	skeleton = sk


## The bones from the root down to b.
func chain_to(b: int) -> Array[int]:
	var chain: Array[int] = []
	var i := b
	while i >= 0:
		chain.push_front(i)
		i = skeleton.get_bone_parent(i)
	return chain


## The +Z of root (the body's scene root above the skeleton) in skeleton space.
func forward_of(root: Node3D) -> Vector3:
	var b := Basis.IDENTITY
	var n: Node = skeleton
	while n != null and n != root:
		if n is Node3D:
			b = (n as Node3D).transform.basis * b
		n = n.get_parent()
	return (b.inverse() * Vector3.BACK).normalized()


## The position (skeleton metres) of the chain's last bone at phase ph of clip a0 blended toward
## a1 by w.
func end_pos(a0: Animation, a1: Animation, w: float, chain: Array, ph: float) -> Vector3:
	var t0 := ph * a0.length
	var t1 := ph * a1.length
	var ms := skeleton.motion_scale
	var xf := Transform3D.IDENTITY
	for b: int in chain:
		var rest := skeleton.get_bone_rest(b)
		var p := rest.origin
		var rot := rest.basis.get_rotation_quaternion()
		if b != chain[0]:
			var k0 := _track(a0, b)
			var k1 := _track(a1, b) if w > 0.0 else k0
			var r0 := a0.rotation_track_interpolate(k0.x, t0) if k0.x >= 0 else rot
			var r1 := a1.rotation_track_interpolate(k1.x, t1) if k1.x >= 0 else rot
			rot = r0.slerp(r1, w) if w > 0.0 else r0
			var p0 := a0.position_track_interpolate(k0.y, t0) * ms if k0.y >= 0 else p
			var p1 := a1.position_track_interpolate(k1.y, t1) * ms if k1.y >= 0 else p
			p = p0.lerp(p1, w)
		xf = xf * Transform3D(Basis(rot).scaled(rest.basis.get_scale()), p)
	return xf.origin


## (rotation track, position track) of bone b in clip a; -1 where it has none. Cached per clip.
func _track(a: Animation, b: int) -> Vector2i:
	var key := "%d|%d" % [a.get_instance_id(), b]
	if _tracks.has(key):
		return _tracks[key]
	var path := NodePath("%GeneralSkeleton:" + skeleton.get_bone_name(b))
	var rt := a.find_track(path, Animation.TYPE_ROTATION_3D)
	var r := Vector2i(rt, a.find_track(path, Animation.TYPE_POSITION_3D))
	_tracks[key] = r
	return r
