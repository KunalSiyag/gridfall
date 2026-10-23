"""Build the shared animation clips from the cached sources (headless Blender).

usage: blender --background --factory-startup --python tools/characters/build_clips.py -- \
           <cache> <out> [--only rb_m,rb_f,ual] [--clips name,name]

  <cache>  ~/.cache/gridfall/characters (fetch.py)
  <out>    models/characters of this repo (keep it under $HOME: the Blender flatpak cannot read /tmp)

Writes, under <out>/anim/:
  rb_m.glb, rb_f.glb  one skeleton per gender (the hero body's T-pose rest on the rb_rig clean rig, no
                      mesh) and one action per Rocketbox clip, "<canonical>-loop" for loops, 30 fps
  ual.glb             the Quaternius UAL clips (in place, mannequin deleted), "<canonical>-loop" for loops
  clips.json          per clip: kind, loop, source, frames, speed_mps, phase; build_anim_library.gd
                      reads it after the Godot import
and the three .glb.import files (BoneMap retarget onto %GeneralSkeleton).

Root extraction (HC-characters.md deliverable 5). Every clip first gets the Biped-to-Biped transfer onto
the clean rig (rb_rig.transfer), then:
  travel loops   Root moves on the straight line (p_end - p_0) * t / T with yaw 0; the clip is turned so
                 that line is the character's forward and phase-shifted so frame 0 is the left-heel strike
  static clips   Root sits still under the mean pelvis ground point, facing the mean pelvis heading
  motion clips   Root follows the pelvis ground point (0.1 s smoothing); turns also take the pelvis yaw
                 (0.3 s smoothing); frame 0 is at the origin facing forward
UAL locomotion loops are authored in place; their Root gets the stance-foot ground speed as travel.
"""

import json
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rb_rig  # noqa: E402
from rb_rig import BIP, PELVIS, ROOT  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ANIM_DIR = "Assets/Animations/all_animations_max_motextr_%s/%s.max.fbx"
HERO_FBX = {"m": "Assets/Avatars/Adults/Male_Adult_06/Export/Male_Adult_06.fbx",
	"f": "Assets/Avatars/Adults/Female_Adult_04/Export/Female_Adult_04.fbx"}
L_FOOT = "Bip01 L Foot"
R_FOOT = "Bip01 R Foot"
ROOT_REST = Matrix.Rotation(math.radians(90.0), 4, "X")
LINEAR = bpy.types.Keyframe.bl_rna.properties["interpolation"].enum_items["LINEAR"].value
# Long in-place loops (Rocketbox talks and idles run 30-47 s) are cut to their best-closing window.
MAX_LOOP_S = 12

# canonical: (kind, loop, male source, female source); sources are "<folder>/<file stem>".
# kind: travel (looping locomotion), static (in place), motion (one-shot with root motion), turn.
RB_CLIPS = {
	"idle": ("static", True, "static/m_idle_neutral_01", "static/f_idle_neutral_01"),
	"idle_look": ("static", True, "static/m_idle_look_around_01", "static/f_idle_look_around_01"),
	"idle_wait": ("static", True, "static/m_idle_waiting_01", "static/f_idle_waiting_01"),
	"walk": ("travel", True, "xy/m_walk_neutral_02", "xy/f_walk_neutral_01"),
	"walk_fast": ("travel", True, "xy/m_walk_fast_01", "xy/f_walk_fast_01"),
	"run": ("travel", True, "xy/m_run_neutral", "xy/f_run_neutral"),
	"run_fast": ("travel", True, "xy/m_run_fast_01", "xy/f_run_fast_01"),
	"walk_start": ("motion", False, "xy/m_walk_start", "xy/f_walk_start"),
	"walk_stop": ("motion", False, "xy/m_walk_stop", "xy/f_walk_stop"),
	"run_start": ("motion", False, "xy/m_run_start", "xy/f_run_start"),
	"run_stop": ("motion", False, "xy/m_run_stop", "xy/f_run_stop"),
	"turn_l90": ("turn", False, "xyz/m_turn_left_90", "xyz/f_turn_left_90"),
	"turn_r90": ("turn", False, "xyz/m_turn_right_90", "xyz/f_turn_right_90"),
	"turn_l180_walk": ("turn", False, "xyz/m_turn_left_180_to_walk", "xyz/f_turn_left_180_to_walk"),
	"turn_r180_walk": ("turn", False, "xyz/m_turn_right_180_to_walk", "xyz/f_turn_right_180_to_walk"),
	"talk": ("static", True, "static/m_gestic_talk_neutral_01", "static/f_gestic_talk_neutral_01"),
	"talk_2": ("static", True, "static/m_gestic_talk_neutral_02", "static/f_gestic_talk_neutral_02"),
	"phone": ("static", True, "static/m_cell_phone_talk_01", "xyz/f_cell_phone_talk_01"),
	"wave": ("static", False, "static/m_wave_01", "static/f_wave_01"),
	"knock": ("static", False, "static/m_knock_door", "static/f_knock_door"),
	"door_try": ("static", False, "static/m_try_door_inwards", "static/f_try_door_inwards"),
	"sit_down": ("motion", False, "xyz/m_sit_down_chair_01", "xyz/f_sit_down_chair_01"),
	"sit": ("static", True, "static/m_sit_chair_idle_neutral_01", "static/f_sit_chair_idle_neutral_01"),
	"stand_up": ("motion", False, "xyz/m_sit_stand_up_chair_01", "xyz/f_sit_stand_up_chair_01"),
}

# canonical: (pack, UAL action, loop, travel). travel: the in-place loop walks; Root gets foot speed.
UAL_CLIPS = {
	"jump_start": ("UAL1", "Jump_Start", False, False),
	"fall": ("UAL1", "Jump_Loop", True, False),
	"land": ("UAL1", "Jump_Land", False, False),
	"crouch_idle": ("UAL1", "Crouch_Idle_Loop", True, False),
	"crouch_walk": ("UAL1", "Crouch_Fwd_Loop", True, True),
	"interact": ("UAL1", "Interact", False, False),
	"push": ("UAL1", "Push_Loop", True, False),
	"pickup": ("UAL1", "PickUp_Table", False, False),
	"drive": ("UAL1", "Driving_Loop", True, False),
	"carry": ("UAL2", "Walk_Carry_Loop", True, True),
	"phone_idle": ("UAL2", "Idle_TalkingPhone_Loop", True, False),
	"fold_arms": ("UAL2", "Idle_FoldArms_Loop", True, False),
	"yes": ("UAL2", "Yes", False, False),
	"no": ("UAL2", "Idle_No_Loop", True, False),
	"climb_1m": ("UAL2", "ClimbUp_1m", False, False),
	"knockback": ("UAL2", "Hit_Knockback", False, False),
	"punch_jab": ("UAL1", "Punch_Jab", False, False),
	"punch_cross": ("UAL1", "Punch_Cross", False, False),
	"punch_hook": ("UAL2", "Melee_Hook", False, False),
	"hit_head": ("UAL1", "Hit_Head", False, False),
	"hit_chest": ("UAL1", "Hit_Chest", False, False),
	"dance": ("UAL1", "Dance_Loop", True, False),
	"get_up": ("UAL2", "LayToIdle", False, False),
	"roll": ("UAL1", "Roll", False, False),
	"shout": ("UAL2", "Idle_Rail_Call", True, False),
}
UAL_GLB = {"UAL1": "UAL1/UAL1_Standard.glb", "UAL2": "UAL2/UAL2_Standard.glb"}


# --- Small math helpers -------------------------------------------------------------------------

def ground(m: Matrix) -> Vector:
	t = m.translation
	return Vector((t.x, t.y, 0.0))


def heading(m: Matrix, rest_rot: Quaternion) -> float:
	return rb_rig.yaw_of(m, rest_rot)


def unwrap(angles: list) -> list:
	out = [angles[0]]
	for a in angles[1:]:
		d = (a - out[-1] + math.pi) % (2.0 * math.pi) - math.pi
		out.append(out[-1] + d)
	return out


def smooth(values: list, window: int) -> list:
	"""Centred moving average over `window` frames (clamped at the ends); works on floats or Vectors."""
	if window <= 1:
		return list(values)
	h = window // 2
	n = len(values)
	out = []
	for i in range(n):
		a, b = max(0, i - h), min(n, i + h + 1)
		acc = values[a] * 0.0
		for j in range(a, b):
			acc = acc + values[j]
		out.append(acc / (b - a))
	return out


def frame_xf(pos: Vector, yaw: float) -> Matrix:
	return Matrix.Translation(pos) @ Matrix.Rotation(yaw, 4, "Z")


def apply_all(frames: list, m: Matrix) -> list:
	return [{k: m @ v for k, v in w.items()} for w in frames]


# --- Root extraction ----------------------------------------------------------------------------

def foot_speeds(frames: list, bone: str) -> list:
	"""Horizontal world speed (m/s) of a bone per frame (central differences)."""
	n = len(frames)
	out = []
	for i in range(n):
		a, b = max(0, i - 1), min(n - 1, i + 1)
		d = (ground(frames[b][bone]) - ground(frames[a][bone])).length
		out.append(d * rb_rig.FPS / max(b - a, 1))
	return out


def heel_strike(frames: list, n: int, speed: float) -> int:
	"""First frame of the left foot's stance in a closed cycle of n frames: the foot's ground speed
	drops below a quarter of the travel speed (at least 0.25 m/s), entering its low plateau."""
	v = foot_speeds(frames, L_FOOT)[:n]
	z = [frames[i][L_FOOT].translation.z for i in range(n)]
	th = max(0.25, 0.25 * speed)
	zmin, zmax = min(z), max(z)
	low = [v[i] < th and z[i] < zmin + 0.35 * (zmax - zmin) for i in range(n)]
	starts = [i for i in range(n) if low[i] and not low[(i - 1) % n]]
	if not starts:
		return min(range(n), key=lambda i: z[i])
	# The longest stance plateau is the real one (a run can graze the threshold in the air).
	def plateau(s):
		k = 0
		while k < n and low[(s + k) % n]:
			k += 1
		return k
	return max(starts, key=plateau)


def root_travel(frames: list, rest_rot: Quaternion) -> tuple:
	"""Travel loop: turn the clip so its net travel is forward, phase-shift it to the left-heel strike,
	then lay Root on the straight line. Returns (frames with ROOT, speed m/s, phase shift)."""
	n = len(frames) - 1
	p0, p1 = ground(frames[0][BIP]), ground(frames[n][BIP])
	d = p1 - p0
	# Forward is -Y in Blender; rotate d onto it, and put the start pelvis over the origin.
	yaw = math.atan2(d.x, -d.y)
	turn = Matrix.Rotation(-yaw, 4, "Z") @ Matrix.Translation(-p0)
	frames = apply_all(frames, turn)
	dist = d.length
	speed = dist * rb_rig.FPS / n
	shift = heel_strike(frames, n, speed)
	if shift:
		step = Matrix.Translation((0.0, -dist, 0.0))
		cyc = frames[:n]
		out = []
		for k in range(n + 1):
			j = shift + k
			out.append(cyc[j] if j < n else {b: step @ m for b, m in cyc[j - n].items()})
		p0 = ground(out[0][BIP])
		frames = apply_all(out, Matrix.Translation(-p0))
	# Centre the line on the pelvis: its sway and surge then average out around Root.
	line = [Vector((0.0, -dist * k / n, 0.0)) for k in range(n + 1)]
	mean = sum((ground(frames[k][BIP]) - line[k] for k in range(n)), Vector()) / n
	frames = apply_all(frames, Matrix.Translation(-mean))
	for k, w in enumerate(frames):
		w[ROOT] = Matrix.Translation(line[k]) @ ROOT_REST
	return frames, speed, shift


def root_static(frames: list, rest_rot: Quaternion) -> list:
	"""In-place clip: Root still under the mean pelvis ground point, facing the mean pelvis heading;
	the whole clip is moved so that Root is the origin, facing forward."""
	pts = [ground(w[BIP]) for w in frames]
	c = sum(pts, Vector()) / len(pts)
	hs = unwrap([heading(w[BIP], rest_rot) for w in frames])
	h = sum(hs) / len(hs)
	frames = apply_all(frames, frame_xf(c, h).inverted())
	for w in frames:
		w[ROOT] = ROOT_REST.copy()
	return frames


def root_motion(frames: list, rest_rot: Quaternion, turn: bool) -> list:
	"""One-shot with root motion: Root follows the smoothed pelvis ground point (and the smoothed pelvis
	yaw for turns); frame 0 is moved to the origin facing forward."""
	pts = smooth([ground(w[BIP]) for w in frames], 3)
	hs = unwrap([heading(w[BIP], rest_rot) for w in frames])
	if turn:
		# 0.3 s of smoothing keeps the gait sway from wagging Root.
		hs = smooth(hs, 9)
	else:
		# Starts, stops and sitting keep the facing of their first 0.3 s.
		head = hs[:9]
		hs = [sum(head) / len(head)] * len(hs)
	base = frame_xf(pts[0], hs[0]).inverted()
	frames = apply_all(frames, base)
	for w, p, h in zip(frames, pts, hs):
		w[ROOT] = base @ frame_xf(p, h) @ ROOT_REST
	return frames


# --- Keying -------------------------------------------------------------------------------------

def to_locals(arm, frames: list, bones: list) -> dict:
	"""{bone: (locations, quaternions)} per frame, from world frames; quaternion signs kept continuous."""
	cols = {b: ([], []) for b in bones}
	for w in frames:
		basis = rb_rig.basis_from_worlds(arm, w)
		for b in bones:
			loc, rot, _s = basis[b].decompose()
			rots = cols[b][1]
			if rots and rots[-1].dot(rot) < 0.0:
				rot = -rot
			cols[b][0].append(loc)
			rots.append(rot)
	return cols


def trim_loop(cols: dict, max_frames: int) -> tuple:
	"""A long looping clip cut to its best-closing window of 2/3..1 of max_frames, with the last 0.5 s
	cross-faded into the frames before the window start so the seam is exact. Returns (cols, first, last)."""
	n = len(next(iter(cols.values()))[1])
	fade = rb_rig.FPS // 2
	if n <= max_frames:
		return cols, 0, n - 1
	q = np.array([[[r.w, r.x, r.y, r.z] for r in cols[b][1]] for b in cols])  # bones x frames x 4
	hip = np.array([[v.x, v.y, v.z] for v in cols[BIP][0]])
	best = None
	for lag in range(max_frames * 2 // 3, max_frames + 1):
		a = np.arange(fade, n - lag)
		if len(a) == 0:
			continue
		ang = (1.0 - np.abs((q[:, a, :] * q[:, a + lag, :]).sum(axis=2))).sum(axis=0)
		cost = ang + 20.0 * ((hip[a] - hip[a + lag]) ** 2).sum(axis=1)
		i = int(np.argmin(cost))
		if best is None or cost[i] < best[0]:
			best = (float(cost[i]), int(a[i]), int(a[i] + lag))
	_c, first, last = best
	out = {}
	for b, (locs, rots) in cols.items():
		nl, nr = locs[first:last + 1], rots[first:last + 1]
		for k in range(fade + 1):
			# Tail frame last - fade + k blends into its counterpart before the window start.
			j = len(nr) - 1 - fade + k
			src = first - fade + k
			t = k / fade
			w = t * t * (3.0 - 2.0 * t)
			rq = rots[src] if rots[src].dot(nr[j]) >= 0.0 else -rots[src]
			nr[j] = nr[j].slerp(rq, w)
			nl[j] = nl[j].lerp(locs[src], w)
		out[b] = (nl, nr)
	return out, first, last


def key_action(arm, name: str, cols: dict):
	"""A new action on arm keying every bone's quaternion at frames 0..n-1, and the location of Root and
	Bip01 (the transfer keeps every other bone at its rest offset). Linear keys, exported as they are."""
	act = bpy.data.actions.new(name)
	act.use_fake_user = True
	if arm.animation_data is None:
		arm.animation_data_create()
	arm.animation_data.action = act
	for b, (locs, rots) in cols.items():
		channels = [("rotation_quaternion", rots, 4)]
		if b in (ROOT, BIP):
			channels.insert(0, ("location", locs, 3))
		for path, data, comps in channels:
			for i in range(comps):
				fc = act.fcurve_ensure_for_datablock(arm, 'pose.bones["%s"].%s' % (b, path), index=i, group_name=b)
				fc.keyframe_points.add(len(data))
				co = []
				for f, v in enumerate(data):
					co += [float(f), float(v[i])]
				fc.keyframe_points.foreach_set("co", co)
				fc.keyframe_points.foreach_set("interpolation", [LINEAR] * len(data))
				fc.update()
	return act


def keyed_bones(arm) -> list:
	"""Root, Bip01 and every bone the Rocketbox BoneMap maps (the importer drops the rest; the pelvis
	stays at its rest under Bip01, rb_rig.transfer)."""
	mapped = bonemap_targets("bonemap_rocketbox.tres") | {ROOT, BIP}
	return [b.name for b in arm.data.bones if b.name in mapped]


# --- Rocketbox ----------------------------------------------------------------------------------

def build_rb(cache: str, out: str, gender: str, only_clips: list, report: dict) -> None:
	rb_rig.reset()
	src = rb_rig.import_fbx(os.path.join(cache, "rocketbox", HERO_FBX[gender]))
	arm, parents = rb_rig.build_rig(src, "Armature")
	for o in list(bpy.context.scene.objects):
		if o is not arm:
			bpy.data.objects.remove(o, do_unlink=True)
	for a in list(bpy.data.actions):
		bpy.data.actions.remove(a)
	tgt_rest = {b.name: b.matrix_local.copy() for b in arm.data.bones}
	order = [b.name for b in arm.data.bones if b.name not in (ROOT, BIP)]
	bones = keyed_bones(arm)
	rest_rot = tgt_rest[BIP].to_quaternion()
	for canon, (kind, loop, m_src, f_src) in RB_CLIPS.items():
		if only_clips and canon not in only_clips:
			continue
		rel = m_src if gender == "m" else f_src
		folder, stem = rel.split("/")
		path = os.path.join(cache, "rocketbox", ANIM_DIR % (folder, stem))
		clip = rb_rig.import_fbx(path)
		act_src = clip.animation_data.action
		f0, f1 = (int(round(x)) for x in act_src.frame_range)
		frames = []
		for f in range(f0, f1 + 1):
			frames.append(rb_rig.transfer(rb_rig.sample_worlds(clip, f), tgt_rest, parents, order))
		for o in list(bpy.context.scene.objects):
			if o is not arm:
				bpy.data.objects.remove(o, do_unlink=True)
		bpy.data.actions.remove(act_src)
		info = {"kind": kind, "loop": loop, "source": "rocketbox:" + rel, "frames": len(frames), "seconds": round((len(frames) - 1) / rb_rig.FPS, 4)}
		if kind == "travel":
			frames, speed, shift = root_travel(frames, rest_rot)
			info.update(speed_mps=round(speed, 4), phase_shift=shift)
		elif kind == "static":
			frames = root_static(frames, rest_rot)
			info["speed_mps"] = 0.0
		else:
			frames = root_motion(frames, rest_rot, kind == "turn")
			r0, r1 = frames[0][ROOT].translation, frames[-1][ROOT].translation
			info["root_travel_m"] = round((r1 - r0).length, 4)
			info["root_yaw_deg"] = round(math.degrees(rb_rig.yaw_of(frames[-1][ROOT] @ ROOT_REST.inverted(), Quaternion())), 1)
			info["speed_mps"] = 0.0
		if kind == "travel":
			info["feet_z0"] = [round(frames[0][L_FOOT].translation.z, 4), round(frames[0][R_FOOT].translation.z, 4)]
		cols = to_locals(arm, frames, bones)
		if kind == "static" and loop:
			cols, first, last = trim_loop(cols, MAX_LOOP_S * rb_rig.FPS)
			if last - first + 1 != len(frames):
				info.update(window=[first, last], frames=last - first + 1, seconds=round((last - first) / rb_rig.FPS, 4))
		key_action(arm, canon + ("-loop" if loop else ""), cols)
		report.setdefault(canon, {})[gender] = info
		print("@@CLIP %s %s %s" % (gender, canon, json.dumps(info)), flush=True)
	arm.animation_data.action = None
	glb = os.path.join(out, "anim", "rb_%s.glb" % gender)
	export_anim(glb)
	write_anim_import(glb, "res://models/characters/bonemap_rocketbox.tres")


# --- Quaternius UAL -----------------------------------------------------------------------------

def ual_foot_speed(arm, act, f0: int, f1: int) -> float:
	"""Ground speed of the stance foot in an in-place walk: the median backward speed of whichever
	foot is lower, in metres per second."""
	sc = bpy.context.scene
	arm.animation_data.action = act
	fps = sc.render.fps / sc.render.fps_base
	prev = None
	vs = []
	for f in range(f0, f1 + 1):
		sc.frame_set(f)
		pl = arm.matrix_world @ arm.pose.bones["foot_l"].head
		pr = arm.matrix_world @ arm.pose.bones["foot_r"].head
		cur = pl if pl.z < pr.z else pr
		side = "l" if pl.z < pr.z else "r"
		if prev is not None and prev[0] == side:
			vs.append(-(cur.y - prev[1].y) * fps)
		prev = (side, cur.copy())
	vs.sort()
	return abs(vs[len(vs) // 2]) if vs else 0.0


def build_ual(cache: str, out: str, only_clips: list, report: dict) -> None:
	rb_rig.reset()
	sc = bpy.context.scene
	keep = {}
	arm = None
	for pack in ("UAL1", "UAL2"):
		before_actions = set(bpy.data.actions)
		before_objs = set(bpy.data.objects)
		# glTF keys are in seconds; at 24 fps every UAL key lands on a whole frame.
		sc.render.fps = 24
		bpy.ops.import_scene.gltf(filepath=os.path.join(cache, "quaternius", UAL_GLB[pack]))
		new_objs = [o for o in bpy.data.objects if o not in before_objs]
		new_arm = next(o for o in new_objs if o.type == "ARMATURE")
		for a in bpy.data.actions:
			if a in before_actions:
				continue
			want = [c for c, v in UAL_CLIPS.items() if v[0] == pack and v[1] == a.name and (not only_clips or c in only_clips)]
			if want:
				keep[want[0]] = a
			else:
				bpy.data.actions.remove(a)
		if arm is None:
			arm = new_arm
			for o in new_objs:
				if o is not arm:
					bpy.data.objects.remove(o, do_unlink=True)
		else:
			for o in new_objs:
				bpy.data.objects.remove(o, do_unlink=True)
	arm.name = "Armature"
	fps = sc.render.fps / sc.render.fps_base
	bmap = bonemap_targets("bonemap_ual.tres")
	for canon, act in sorted(keep.items()):
		pack, src_name, loop, travel = UAL_CLIPS[canon]
		f0, f1 = (int(round(x)) for x in act.frame_range)
		# UAL2's actions were made for the deleted second armature: bind their one slot to ours.
		arm.animation_data.action = act
		arm.animation_data.action_slot = act.slots[0]
		prune_ual(act, bmap)
		info = {"kind": "travel" if travel else "ual", "loop": loop, "source": "quaternius:%s/%s" % (pack, src_name),
			"frames": f1 - f0 + 1, "seconds": round((f1 - f0) / fps, 4), "speed_mps": 0.0}
		if travel:
			speed = ual_foot_speed(arm, act, f0, f1)
			add_root_travel(arm, act, f0, f1, speed, fps)
			info["speed_mps"] = round(speed, 4)
		act.name = canon + ("-loop" if loop else "")
		act.use_fake_user = True
		report.setdefault(canon, {})["u"] = info
		print("@@CLIP u %s %s" % (canon, json.dumps(info)), flush=True)
	arm.animation_data.action = None
	glb = os.path.join(out, "anim", "ual.glb")
	export_anim(glb)
	write_anim_import(glb, "res://models/characters/bonemap_ual.tres")


def prune_ual(act, mapped: set) -> None:
	"""Drops the channels the importer would drop anyway (unmapped bones, scale, and every location but
	root's and pelvis'): a third of the file."""
	from bpy_extras import anim_utils
	bag = anim_utils.action_get_channelbag_for_slot(act, act.slots[0])
	for fc in list(bag.fcurves):
		bone = fc.data_path.split('"')[1] if fc.data_path.startswith("pose.bones[") else ""
		prop = fc.data_path.rsplit(".", 1)[-1]
		keep = bone in mapped and (prop == "rotation_quaternion" or (prop == "location" and bone in ("root", "pelvis")))
		if not keep:
			bag.fcurves.remove(fc)


def bonemap_targets(name: str) -> set:
	"""Source bone names a BoneMap .tres maps (models/characters/<name>)."""
	out = set()
	with open(os.path.join(HERE, "..", "..", "models", "characters", name)) as f:
		for line in f:
			if line.startswith("bone_map/"):
				out.add(line.split('&"', 1)[1].rsplit('"', 1)[0])
	return out


def add_root_travel(arm, act, f0: int, f1: int, speed: float, fps: float) -> None:
	"""Keys the UAL `root` bone moving forward at `speed` (the in-place clip then travels on Root)."""
	rb = arm.data.bones["root"]
	# Forward in armature space is -Y; express it in the root bone's rest frame.
	fwd = rb.matrix_local.to_3x3().inverted() @ Vector((0.0, -1.0, 0.0))
	fcs = [act.fcurve_ensure_for_datablock(arm, 'pose.bones["root"].location', index=i, group_name="root") for i in range(3)]
	for fc in fcs:
		fc.keyframe_points.clear()
	n = f1 - f0
	for i, fc in enumerate(fcs):
		fc.keyframe_points.add(2)
		fc.keyframe_points.foreach_set("co", [float(f0), 0.0, float(f1), fwd[i] * speed * n / fps])
		for kp in fc.keyframe_points:
			kp.interpolation = "LINEAR"
		fc.update()


# --- Export -------------------------------------------------------------------------------------

def export_anim(path: str) -> None:
	os.makedirs(os.path.dirname(path), exist_ok=True)
	bpy.ops.object.select_all(action="DESELECT")
	bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", export_image_format="NONE",
		export_materials="NONE", export_animations=True, export_animation_mode="ACTIONS",
		export_force_sampling=False, export_optimize_animation_size=False, export_anim_single_armature=True,
		export_reset_pose_bones=True, export_skins=True, export_morph=False, export_yup=True, export_apply=False,
		export_extras=False, export_cameras=False, export_lights=False, export_def_bones=False,
		export_rest_position_armature=True, export_frame_range=False, export_anim_slide_to_zero=False)


def write_anim_import(path: str, bonemap: str) -> None:
	retarget = RETARGET % bonemap
	head = rb_rig.import_header(path, "scene", "PackedScene")
	with open(path + ".import", "w") as f:
		f.write(head)
		f.write(ANIM_PARAMS)
		f.write('_subresources={\n"nodes": {\n"PATH:Armature/Skeleton3D": {\n%s\n}\n}\n}\n' % retarget)
		f.write("gltf/naming_version=2\ngltf/embedded_image_handling=0\n")


ANIM_PARAMS = """nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=true
meshes/generate_lods=true
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=false
skins/use_named_skins=true
animation/import=true
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
"""

RETARGET = """"retarget/bone_map": Resource("%s"),
"retarget/bone_renamer/rename_bones": true,
"retarget/bone_renamer/unique_node/make_unique": true,
"retarget/bone_renamer/unique_node/skeleton_name": "GeneralSkeleton",
"retarget/remove_tracks/except_bone_transform": false,
"retarget/remove_tracks/unimportant_positions": true,
"retarget/remove_tracks/unmapped_bones": true,
"retarget/rest_fixer/apply_node_transforms": true,
"retarget/rest_fixer/fix_silhouette/enable": true,
"retarget/rest_fixer/normalize_position_tracks": true,
"retarget/rest_fixer/overwrite_axis": true"""


def main() -> None:
	argv = sys.argv[sys.argv.index("--") + 1:]
	cache, out = os.path.abspath(argv[0]), os.path.abspath(argv[1])
	only = ["rb_m", "rb_f", "ual"]
	if "--only" in argv:
		only = [s for s in argv[argv.index("--only") + 1].split(",") if s]
	clips = []
	if "--clips" in argv:
		clips = [s for s in argv[argv.index("--clips") + 1].split(",") if s]
	rep_path = os.path.join(out, "anim", "clips.json")
	report = {}
	if os.path.isfile(rep_path):
		with open(rep_path) as f:
			report = json.load(f).get("clips", {})
	for part in only:
		if part == "ual":
			build_ual(cache, out, clips, report)
		else:
			build_rb(cache, out, part[-1], clips, report)
	os.makedirs(os.path.dirname(rep_path), exist_ok=True)
	with open(rep_path, "w") as f:
		json.dump({"note": "Written by tools/characters/build_clips.py; read by build_anim_library.gd. m/f: Rocketbox clips in rb_m.glb / rb_f.glb; u: Quaternius UAL clips in ual.glb, shared by both libraries.",
			"fps": rb_rig.FPS, "clips": dict(sorted(report.items()))}, f, indent=1)
		f.write("\n")
	print("@@CLIPS %d" % len(report))


main()
