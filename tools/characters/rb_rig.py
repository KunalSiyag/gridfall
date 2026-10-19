"""Shared Blender helpers for the Rocketbox character pipeline (build_bodies.py, build_clips.py).

Rocketbox FBX files import with the Biped COM node `Bip01` as the armature *object* (scale 0.01,
rotated -90 deg about Z) and every other Biped node as a bone. build_rig() turns that into a clean
metric armature at the origin:

    Armature (object at identity, scale 1)
      Root          at the origin on the ground, no weights (root motion lives here)
        Bip01       the COM node, a real bone now (BoneMap Hips -> Bip01)
          Bip01 Pelvis, Spine, ... exactly the FBX node frames, in metres

Every Rocketbox skeleton of one gender has identical bone lengths (checked for clips and bodies), and
bone frames are the FBX node frames, so a clip moves onto a body by copying each bone's rotation
relative to its parent (a Biped-to-Biped transfer: exact, no retargeting).
"""

import math

import bpy
from mathutils import Matrix, Quaternion, Vector

ROOT = "Root"
BIP = "Bip01"
PELVIS = "Bip01 Pelvis"
FPS = 30
# Biped hangs the thighs off Spine and the clavicles off Neck. Godot's humanoid profile (and the UAL
# rig) hangs them off Hips and UpperChest; matching that keeps spine and neck motion out of the legs
# and arms when a UAL clip plays on a Rocketbox body. Bone frames do not change, only the parents.
REPARENT = {"Bip01 L Thigh": "Bip01 Pelvis", "Bip01 R Thigh": "Bip01 Pelvis",
	"Bip01 L Clavicle": "Bip01 Spine2", "Bip01 R Clavicle": "Bip01 Spine2"}
# Character forward in Blender space (glTF export maps Blender -Y to +Z, the Godot model front).
FORWARD = Vector((0.0, -1.0, 0.0))


def reset() -> None:
	bpy.ops.wm.read_factory_settings(use_empty=True)
	sc = bpy.context.scene
	sc.render.fps = FPS
	sc.render.fps_base = 1.0


def import_fbx(path: str):
	"""Imports one Rocketbox FBX; returns its armature object (the Bip01 node)."""
	before = set(bpy.data.objects)
	bpy.ops.import_scene.fbx(filepath=path, use_image_search=False, use_anim=True)
	sc = bpy.context.scene
	sc.render.fps = FPS
	sc.render.fps_base = 1.0
	return next(o for o in bpy.data.objects if o not in before and o.type == "ARMATURE" and o.parent is None)


def norm(m: Matrix) -> Matrix:
	"""m without scale (location and rotation only)."""
	loc, rot, _scale = m.decompose()
	return Matrix.LocRotScale(loc, rot, None)


def deform_names(arm) -> list:
	"""Bone names of a Rocketbox armature without the Biped `Nub` end markers, parents first."""
	out = []

	def walk(b):
		if "Nub" not in b.name:
			out.append(b.name)
		for c in b.children:
			walk(c)

	for b in arm.data.bones:
		if b.parent is None:
			walk(b)
	return out


def parent_name(arm, name: str) -> str:
	b = arm.data.bones[name]
	return b.parent.name if b.parent else BIP


def rest_worlds(arm) -> dict:
	"""Metric world rest frames of the Bip01 node and every bone (the object's current transform)."""
	mw = arm.matrix_world.copy()
	out = {BIP: norm(mw)}
	for n in deform_names(arm):
		out[n] = norm(mw @ arm.data.bones[n].matrix_local)
	return out


def sample_worlds(arm, frame: int) -> dict:
	"""Metric world frames of the Bip01 node and every bone at `frame`."""
	bpy.context.scene.frame_set(frame)
	mw = arm.matrix_world.copy()
	out = {BIP: norm(mw)}
	for n in deform_names(arm):
		out[n] = norm(mw @ arm.pose.bones[n].matrix)
	return out


def build_rig(src, name: str = "Armature"):
	"""A clean armature (Root -> Bip01 -> Biped bones, REPARENT applied) whose rest equals src's world
	rest, in metres. Returns (armature object, {bone: parent}). Leaves src untouched."""
	rest = rest_worlds(src)
	names = deform_names(src)
	lengths = {n: max(src.data.bones[n].length * src.matrix_world.to_scale().x, 0.005) for n in names}
	parents = {BIP: ROOT}
	for n in names:
		parents[n] = parent_name(src, n)
		# The new parent is always an ancestor in the source tree, so it is created first.
		if n in REPARENT and REPARENT[n] in names:
			parents[n] = REPARENT[n]
	data = bpy.data.armatures.new(name)
	obj = bpy.data.objects.new(name, data)
	bpy.context.scene.collection.objects.link(obj)
	bpy.context.view_layer.objects.active = obj
	bpy.ops.object.mode_set(mode="EDIT")

	def add(bone: str, m: Matrix, length: float, parent: str = ""):
		eb = data.edit_bones.new(bone)
		eb.head = (0.0, 0.0, 0.0)
		eb.tail = (0.0, length, 0.0)
		eb.matrix = m
		eb.use_connect = False
		if parent:
			eb.parent = data.edit_bones[parent]
		return eb

	add(ROOT, Matrix.Rotation(math.radians(90.0), 4, "X"), 0.2).use_deform = False
	add(BIP, rest[BIP], 0.15, ROOT).use_deform = False
	for n in names:
		add(n, rest[n], lengths[n], parents[n])
	bpy.ops.object.mode_set(mode="OBJECT")
	for pb in obj.pose.bones:
		pb.rotation_mode = "QUATERNION"
	return obj, parents


def transfer(src_w: dict, tgt_rest: dict, parents: dict, order: list) -> dict:
	"""Target world frames that reproduce src's pose on the target rig: every bone keeps its rotation
	relative to its parent; offsets come from the target rest. The pelvis' motion relative to the COM
	is folded into Bip01 (the importer drops tracks of the unmapped Pelvis), so Pelvis matches src.
	Bones missing from src keep their rest relative to their parent."""
	pel_rest = tgt_rest[BIP].inverted() @ tgt_rest[PELVIS]
	out = {BIP: src_w[PELVIS] @ pel_rest.inverted()}
	for n in order:
		p = parents[n]
		if n == PELVIS:
			out[n] = out[BIP] @ pel_rest
			continue
		rest_rel = tgt_rest[p].inverted() @ tgt_rest[n]
		if n not in src_w or p not in src_w:
			# A bone the source rig lacks (a ponytail, say) keeps its rest relative to its parent.
			out[n] = out[p] @ rest_rel
			continue
		local_rot = (src_w[p].inverted() @ src_w[n]).to_quaternion()
		out[n] = out[p] @ Matrix.Translation(rest_rel.translation) @ local_rot.to_matrix().to_4x4()
	return out


def basis_from_worlds(arm, worlds: dict) -> dict:
	"""{bone: matrix_basis} that put each pose bone at worlds[bone] (armature at identity)."""
	out = {}
	for pb in arm.pose.bones:
		b = pb.bone
		w = worlds[b.name]
		if b.parent is None:
			out[b.name] = b.matrix_local.inverted() @ w
		else:
			rest_rel = b.parent.matrix_local.inverted() @ b.matrix_local
			out[b.name] = rest_rel.inverted() @ worlds[b.parent.name].inverted() @ w
	return out


def yaw_of(m: Matrix, rest_rot: Quaternion) -> float:
	"""Heading (radians, CCW about +Z) of a frame relative to its rest heading, from FORWARD."""
	f = (m.to_quaternion() @ rest_rot.inverted()) @ FORWARD
	# Rz(t) maps (0, -1) to (sin t, -cos t).
	return math.atan2(f.x, -f.y)


def key_pose(arm, basis: dict, frame: int, prev: dict) -> None:
	"""Keys location and rotation of every pose bone at frame (quaternion signs kept continuous)."""
	for pb in arm.pose.bones:
		loc, rot, _s = basis[pb.name].decompose()
		q = prev.get(pb.name)
		if q is not None and q.dot(rot) < 0.0:
			rot = -rot
		prev[pb.name] = rot
		pb.location = loc
		pb.rotation_quaternion = rot
		pb.keyframe_insert("location", frame=frame, group=pb.name)
		pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)


def set_pose(arm, basis: dict) -> None:
	for pb in arm.pose.bones:
		loc, rot, _s = basis[pb.name].decompose()
		pb.location = loc
		pb.rotation_quaternion = rot
	bpy.context.view_layer.update()
