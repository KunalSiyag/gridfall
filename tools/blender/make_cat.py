"""Build the street cat (models/real/animals/cat.glb) from Quaternius' Cat (Animal Pack Vol.2, CC0).

The source rig has two clips, Idle and Walking, driven by leg IK. This script renames the bones,
bakes those clips to plain bone keys and drops the IK, smooths the mesh (one subdivision), writes
the coat fields the game's cat shader reads, poses the rest of the clips in code (trot, run, sit,
loaf, sleep, groom, stalk, crouch, pounce, hiss, startle and stretch) and exports a GLB that faces
+Z like the dogs. Looping clips carry the "-loop" suffix Godot's importer turns into a loop.

Coat fields (scripts/fp/animals/cat_coat.gdshader reads them):
    UV       (forward, up) of the rest pose, in model units
    UV2      (left, distance along the tail; 0 off the tail)
    COLOR_0  r: the order white spreads in (0 the paws and chest first, 1 the tail last),
             g: a smooth noise for tortoiseshell and calico patches, b: 1 on the pink nose and
             inner ears

Source: https://opengameart.org/content/animated-animales-low-poly ("Animal Pack Vol.2 by
@Quaternius.zip"). Blender's flatpak sandbox cannot read the host /tmp, so unzip it under
~/.cache/gridfall_quaternius (or point GRIDFALL_QUATERNIUS_ROOT at the folder holding it).

Usage:
    blender -b --python /ABS/tools/blender/make_cat.py -- [--out PATH] [--renders DIR]
"""

import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector, noise

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC_ROOT = os.environ.get("GRIDFALL_QUATERNIUS_ROOT", os.path.expanduser("~/.cache/gridfall_quaternius"))
SRC = os.path.join(SRC_ROOT, "Animal Pack Vol.2 by @Quaternius", "Blends", "Cat.blend")
OUT = os.path.join(PROJECT_ROOT, "models", "real", "animals", "cat.glb")
FPS = 24

RENAME = {
    "Bone": "Hips", "Bone.001": "Spine", "Bone.002": "Neck", "Bone.003": "Head",
    "Bone.004": "Tail1", "Bone.005": "Tail2", "Bone.006": "Tail3", "Bone.007": "Tail4",
    "Bone.008": "Thigh_L", "Bone.009": "Shin_L", "Bone.010": "Paw_HL",
    "Bone.011": "Thigh_R", "Bone.012": "Shin_R", "Bone.013": "Paw_HR",
    "Bone.014": "Arm_R", "Bone.015": "Forearm_R", "Bone.016": "Paw_FR",
    "Bone.017": "Arm_L", "Bone.018": "Forearm_L", "Bone.019": "Paw_FL",
}
IK_BONES = ["IKFrontRight", "IKFrontLeft", "IKBackRight", "IKBackLeft"]
TAIL = ["Tail1", "Tail2", "Tail3", "Tail4"]
CHAIN = {
    "FL": ("Arm_L", "Forearm_L", "Paw_FL"), "FR": ("Arm_R", "Forearm_R", "Paw_FR"),
    "HL": ("Thigh_L", "Shin_L", "Paw_HL"), "HR": ("Thigh_R", "Shin_R", "Paw_HR"),
}
X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
I4 = Matrix.Identity(4)


def args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    out = {"out": OUT, "renders": ""}
    for k in range(0, len(argv) - 1, 2):
        out[argv[k].lstrip("-")] = argv[k + 1]
    return out


def fcurves(act):
    try:
        return list(act.fcurves)
    except AttributeError:  # Blender 5 layered actions
        return [fc for ly in act.layers for st in ly.strips for cb in st.channelbags for fc in cb.fcurves]


# ------------------------------------------------------------------ the source rig


def rename(arm, mesh):
    for old, new in RENAME.items():
        arm.data.bones[old].name = new
    for act in bpy.data.actions:
        for fc in fcurves(act):
            name = fc.data_path.split('"')[1] if '"' in fc.data_path else ""
            if name in RENAME:
                fc.data_path = fc.data_path.replace('"%s"' % name, '"%s"' % RENAME[name])
    for g in mesh.vertex_groups:
        g.name = RENAME.get(g.name, g.name)


def bake(arm, action, deform):
    """The IK-driven action as plain local bone matrices, one dict per frame."""
    act = bpy.data.actions[action]
    arm.animation_data.action = act
    frames = []
    for f in range(int(act.frame_range[0]), int(act.frame_range[1]) + 1):
        bpy.context.scene.frame_set(f)
        bpy.context.view_layer.update()
        pose = {}
        for n in deform:
            pb = arm.pose.bones[n]
            pose[n] = arm.convert_space(pose_bone=pb, matrix=pb.matrix, from_space="POSE", to_space="LOCAL").copy()
        frames.append(pose)
    return frames


def strip_ik(arm):
    for pb in arm.pose.bones:
        for c in list(pb.constraints):
            pb.constraints.remove(c)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for n in IK_BONES:
        eb = arm.data.edit_bones.get(n)
        if eb is not None:
            arm.data.edit_bones.remove(eb)
    bpy.ops.object.mode_set(mode="OBJECT")
    for name in ("Idle", "Walking"):
        bpy.data.actions.remove(bpy.data.actions[name])


def smooth(mesh):
    """One Catmull-Clark level (the weights follow), smooth shading, sharp edges kept."""
    bpy.ops.object.select_all(action="DESELECT")
    mesh.select_set(True)
    bpy.context.view_layer.objects.active = mesh
    mod = mesh.modifiers.new("Smooth", "SUBSURF")
    mod.levels = 1
    mod.render_levels = 1
    bpy.ops.object.modifier_move_to_index(modifier="Smooth", index=0)
    bpy.ops.object.modifier_apply(modifier="Smooth")
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(60))


# ------------------------------------------------------------------ coat fields


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def white_order(p, kind):
    """0 where white spots first (the original white socks, chest and chin), 1 for the tail."""
    if kind == "White":
        return 0.12
    if kind == "Pink":
        return 0.99
    if p.x < -1.9 and p.z > 2.25:
        return 0.97
    if p.x > 1.95:
        return 0.3 + 0.62 * smoothstep(2.55, 3.35, p.z)
    return 0.2 + 0.72 * smoothstep(0.9, 2.65, p.z)


def tail_param(mesh, v, bones, arm):
    """Distance along the tail (model units) of a vertex weighted mostly to a tail bone, else 0."""
    best, w = None, 0.0
    for g in v.groups:
        name = mesh.vertex_groups[g.group].name
        if g.weight > w:
            best, w = name, g.weight
    if best not in TAIL:
        return 0.0
    k = TAIL.index(best)
    b = arm.data.bones[best]
    seg = b.tail_local - b.head_local
    t = min(max((v.co - b.head_local).dot(seg) / seg.length_squared, 0.0), 1.0)
    return bones[k] + t * seg.length


def write_fields(mesh, arm):
    me = mesh.data
    kinds = [m.name for m in me.materials]
    starts = [0.0]
    for n in TAIL:
        starts.append(starts[-1] + arm.data.bones[n].length)
    tails = [tail_param(mesh, v, starts, arm) for v in me.vertices]
    rest = me.uv_layers.new(name="rest")
    rest2 = me.uv_layers.new(name="rest2")
    col = me.color_attributes.new(name="fields", type="FLOAT_COLOR", domain="CORNER")
    for poly in me.polygons:
        kind = kinds[poly.material_index]
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            p = me.vertices[vi].co
            # glTF flips v (v' = 1 - v), so store 1 - value to read the value back in Godot.
            rest.data[li].uv = (p.x, 1.0 - p.z)
            rest2.data[li].uv = (p.y, 1.0 - tails[vi])
            patch = 0.5 + 0.5 * noise.noise(p * 0.85 + Vector((3.1, 7.7, 1.3)))
            col.data[li].color = (white_order(p, kind), patch, 1.0 if kind == "Pink" else 0.0, 1.0)
    me.color_attributes.active_color = col
    me.color_attributes.render_color_index = me.color_attributes.find("fields")


def one_material(mesh):
    """One matte material; the game swaps in its coat shader."""
    mat = bpy.data.materials.new("Cat")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.9
    bsdf.inputs["Metallic"].default_value = 0.0
    attr = nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "fields"
    mat.node_tree.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
    me = mesh.data
    me.materials.clear()
    me.materials.append(mat)
    for p in me.polygons:
        p.material_index = 0


# ------------------------------------------------------------------ posing


class Rig:
    """Bone poses built in armature space on top of the rest pose, written as local keys."""

    def __init__(self, arm, deform):
        self.arm = arm
        self.deform = deform
        self.rest = {b.name: b.matrix_local.copy() for b in arm.data.bones}
        self.parent = {b.name: (b.parent.name if b.parent else None) for b in arm.data.bones}
        self.length = {b.name: b.length for b in arm.data.bones}
        self.local = {
            n: (self.rest[n] if self.parent[n] is None else self.rest[self.parent[n]].inverted() @ self.rest[n])
            for n in self.rest
        }
        self.basis = {n: I4.copy() for n in deform}

    def reset(self):
        self.basis = {n: I4.copy() for n in self.deform}

    def mat(self, n):
        par = self.parent[n]
        return (I4 if par is None else self.mat(par)) @ self.local[n] @ self.basis[n]

    def head(self, n):
        return self.mat(n).translation.copy()

    def tail(self, n):
        return (self.mat(n) @ Vector((0, self.length[n], 0, 1))).to_3d()

    def turn(self, n, axis, angle):
        if abs(angle) > 1e-7:
            la = (self.rest[n].to_3x3().inverted() @ axis).normalized()
            self.basis[n] = self.basis[n] @ Quaternion(la, angle).to_matrix().to_4x4()

    def move(self, n, off):
        la = self.rest[n].to_3x3().inverted() @ Vector(off)
        self.basis[n] = Matrix.Translation(la) @ self.basis[n]

    def aim(self, n, direction):
        m0 = self.mat(n)
        cur = (m0.to_3x3() @ Y).normalized()
        q = cur.rotation_difference(direction.normalized())
        m = Matrix.Translation(m0.translation) @ (q.to_matrix() @ m0.to_3x3()).to_4x4()
        self.basis[n] = self.basis[n] @ (m0.inverted() @ m)

    def leg(self, upper, lower, target, pole):
        j = self.head(upper)
        lu, ll = self.length[upper], self.length[lower]
        d = target - j
        dist = min(max(d.length, abs(lu - ll) + 1e-3), lu + ll - 1e-4)
        dn = d.normalized()
        a = (lu * lu - ll * ll + dist * dist) / (2 * dist)
        h = math.sqrt(max(lu * lu - a * a, 0.0))
        pv = (pole - dn * pole.dot(dn)).normalized()
        knee = j + dn * a + pv * h
        self.aim(upper, knee - j)
        self.aim(lower, j + dn * dist - knee)

    def reach(self, k, target):
        """How far past its reach the foot target of leg k is (0 when within it)."""
        up, lo, _paw = CHAIN[k]
        return max(0.0, (target - self.head(up)).length - 0.995 * (self.length[up] + self.length[lo]))

    def keys(self, frame):
        for n in self.deform:
            pb = self.arm.pose.bones[n]
            pb.rotation_mode = "QUATERNION"
            loc, rot, _s = self.basis[n].decompose()
            pb.location = loc
            pb.rotation_quaternion = rot
            pb.scale = (1, 1, 1)
            pb.keyframe_insert("rotation_quaternion", frame=frame, group=n)
            pb.keyframe_insert("location", frame=frame, group=n)


NEUTRAL = {
    "FL": Vector((1.111, 0.395, 0.043)), "FR": Vector((1.111, -0.4, 0.043)),
    "HL": Vector((-1.994, 0.527, 0.043)), "HR": Vector((-2.001, -0.525, 0.043)),
}


class Pose:
    """One frame: the body (hips offset, pitch nose up, yaw left, roll), the tail (lower, side per
    bone), the feet and paw pitch (+ toes down), and for each leg where its elbow or knee points."""

    def __init__(self):
        self.hips = Vector()
        self.body = {"Hips": [0.0, 0.0, 0.0], "Spine": [0.0, 0.0, 0.0], "Neck": [0.0, 0.0, 0.0], "Head": [0.0, 0.0, 0.0]}
        self.tail = [(0.0, 0.0)] * 4
        self.feet = {k: v.copy() for k, v in NEUTRAL.items()}
        self.paw = {k: 0.0 for k in NEUTRAL}
        self.elbows_up = 0.0
        self.reach_fn = None
        # Planted poses lower the hips until every foot reaches the ground; gaits let a foot hang.
        self.planted = False

    def bend(self, bone, pitch=0.0, yaw=0.0, roll=0.0):
        self.body[bone] = [pitch, yaw, roll]
        return self


def pose_rig(rig, p):
    """Poses rig as p (a planted pose lowers the hips until every foot can reach its spot)."""
    drop = 0.0
    for _k in range(4):
        rig.reset()
        rig.move("Hips", p.hips - Vector((0, 0, drop)))
        for bone, (pitch, yaw, roll) in p.body.items():
            rig.turn(bone, Z, yaw)
            rig.turn(bone, Y, -pitch)
            rig.turn(bone, X, roll)
        for k, n in enumerate(TAIL):
            rig.turn(n, Y, p.tail[k][0])
            rig.turn(n, Z, p.tail[k][1])
        if p.reach_fn is not None:
            p.reach_fn(rig, p)
        over = max(rig.reach(k, p.feet[k]) for k in CHAIN) if p.planted else 0.0
        if over < 1e-3:
            break
        drop += over
    fwd = (rig.mat("Spine").to_3x3() @ Y).normalized()
    fwd = Vector((fwd.x, fwd.y, 0.0)).normalized()
    for k, (up, lo, paw) in CHAIN.items():
        out = Vector((0, 0.25 if k.endswith("L") else -0.25, 0))
        if k[0] == "F":
            pole = -fwd + out + Z * p.elbows_up
        else:
            pole = fwd + out
        rig.leg(up, lo, p.feet[k], pole)
        a = p.paw[k]
        rig.aim(paw, Vector((fwd.x * math.cos(a), fwd.y * math.cos(a), -math.sin(a))))


def step_foot(phase, duty, sweep, lift):
    """(forward, up, swing 0..1) of a foot at cycle phase (0 = touch-down)."""
    phase %= 1.0
    if phase < duty:
        return sweep * (0.5 - phase / duty), 0.0, 0.0
    s = (phase - duty) / (1.0 - duty)
    return sweep * (s * s * (3 - 2 * s) - 0.5), lift * math.sin(math.pi * s), math.sin(math.pi * s)


def gait(p, t, phases, duty, sweep, lift, curl, shift=(0.0, 0.0)):
    for k, ph in phases.items():
        f, u, sw = step_foot(t - ph, duty, sweep, lift * (1.0 if k[0] == "F" else 0.85))
        p.feet[k] = NEUTRAL[k] + Vector((f + (shift[0] if k[0] == "F" else shift[1]), 0, u))
        p.paw[k] = curl * sw if k[0] == "F" else -0.5 * curl * sw


def ease(a, b, t):
    return smoothstep(a, b, t) if b > a else float(t >= a)


def wave(t, n=1.0, ph=0.0):
    return math.sin(2.0 * math.pi * n * t + ph)


# ------------------------------------------------------------------ the clips


TROT = {"duty": 0.45, "sweep": 2.2}
RUN = {"duty": 0.25, "sweep": 2.4}
STALK = {"duty": 0.75, "sweep": 1.0}


def trot(t):
    p = Pose()
    gait(p, t, {"FL": 0.0, "HR": 0.0, "FR": 0.5, "HL": 0.5}, TROT["duty"], TROT["sweep"], 0.45, 1.0)
    p.hips = Vector((0, 0, -0.08 - 0.06 * (0.5 + 0.5 * math.cos(4 * math.pi * t))))
    p.bend("Spine", roll=0.03 * wave(t))
    p.bend("Neck", pitch=0.04 * math.cos(4 * math.pi * t))
    sw = [0.0, 0.06, 0.08, 0.1]
    p.tail = [(0.55, 0.0)] + [(0.12 - 0.04 * k, sw[k + 1] * wave(t, 1, -0.6 * (k + 1))) for k in range(3)]
    return p


def run(t):
    p = Pose()
    gait(p, t, {"HL": 0.0, "HR": 0.08, "FL": 0.5, "FR": 0.6}, RUN["duty"], RUN["sweep"], 0.55, 1.3, (0.2, -0.05))
    flex = wave(t, 1, 0.5)
    p.hips = Vector((0, 0, -0.3 + 0.12 * math.cos(2 * math.pi * t)))
    p.bend("Hips", pitch=0.16 * flex).bend("Spine", pitch=-0.32 * flex)
    p.bend("Neck", pitch=0.2 * flex - 0.25).bend("Head", pitch=0.1)
    p.tail = [(1.35, 0.0), (0.05 - 0.1 * flex, 0.0), (0.0, 0.0), (-0.1, 0.0)]
    return p


def sitting(p, breath):
    p.hips = Vector((0.35, 0, -1.40 + 0.01 * breath))
    p.bend("Hips", pitch=0.78).bend("Spine", pitch=-0.3).bend("Neck", pitch=-0.25).bend("Head", pitch=-0.45)
    p.feet["FL"] = Vector((0.95, 0.3, 0.043))
    p.feet["FR"] = Vector((0.95, -0.3, 0.043))
    p.feet["HL"] = Vector((-0.75, 0.62, 0.15))
    p.feet["HR"] = Vector((-0.75, -0.62, 0.15))
    p.tail = [(1.7, 0.0), (0.5, 0.5), (0.1, 0.6), (0.0, 0.5)]


def sit(t):
    p = Pose()
    sitting(p, wave(t))
    p.tail[3] = (0.0, 0.5 + 0.15 * wave(t))
    return p


def groom(t):
    p = Pose()
    sitting(p, 0.0)
    lick = wave(t, 5)
    p.bend("Spine", pitch=-0.3, yaw=0.06).bend("Neck", pitch=-0.05)
    p.bend("Head", pitch=0.05 + 0.12 * lick, yaw=0.25, roll=0.25)

    def paw_to_mouth(rig, pose):
        pose.feet["FL"] = rig.tail("Head") + Vector((-0.35, 0.18, -0.55 - 0.08 * lick))

    p.reach_fn = paw_to_mouth
    p.paw["FL"] = -1.3
    p.elbows_up = 0.8
    return p


def lying(p, breath):
    p.hips = Vector((0.05, 0, -1.22 + 0.015 * breath))
    p.bend("Spine", pitch=0.02).bend("Neck", pitch=0.15).bend("Head", pitch=-0.1)
    p.feet["FL"] = Vector((0.75, 0.33, 0.12))
    p.feet["FR"] = Vector((0.75, -0.33, 0.12))
    p.paw["FL"] = p.paw["FR"] = -2.6
    p.feet["HL"] = Vector((-0.55, 0.62, 0.1))
    p.feet["HR"] = Vector((-0.55, -0.62, 0.1))
    p.tail = [(2.0, 0.0), (0.15, 0.5), (0.0, 0.5), (0.0, 0.4)]


def loaf(t):
    p = Pose()
    lying(p, wave(t))
    return p


def sleep(t):
    p = Pose()
    lying(p, wave(t))
    p.hips.z = -1.25 + 0.025 * wave(t)
    p.bend("Neck", pitch=-0.45).bend("Head", pitch=0.35, yaw=0.2, roll=0.15)
    p.tail = [(2.0, 0.0), (0.15, 0.8), (0.0, 0.7), (0.0, 0.6)]
    return p


def stalk(t):
    p = Pose()
    gait(p, t, {"HL": 0.0, "FL": 0.25, "HR": 0.5, "FR": 0.75}, STALK["duty"], STALK["sweep"], 0.28, 0.8, (0.35, 0.1))
    p.hips = Vector((0, 0, -0.8 + 0.03 * math.cos(4 * math.pi * t)))
    p.bend("Spine", pitch=0.06).bend("Neck", pitch=-0.5).bend("Head", pitch=0.4)
    p.elbows_up = 1.2
    p.tail = [(1.55, 0.03 * wave(t)), (0.1, 0.0), (0.0, 0.1 * wave(t, 2)), (-0.2, 0.25 * wave(t, 2, 1.0))]
    return p


def crouch(t):
    p = Pose()
    w = wave(t, 2)
    p.hips = Vector((0.0, 0.06 * w, -0.95))
    p.bend("Hips", yaw=0.07 * w).bend("Spine", pitch=0.08, yaw=-0.07 * w)
    p.bend("Neck", pitch=-0.5).bend("Head", pitch=0.45)
    for k in ("FL", "FR"):
        p.feet[k] = NEUTRAL[k] + Vector((0.45, 0, 0))
    for k in ("HL", "HR"):
        p.feet[k] = NEUTRAL[k] + Vector((0.55, 0, 0))
    p.elbows_up = 1.4
    p.tail = [(1.6, 0.0), (0.05, 0.0), (0.0, 0.15 * w), (-0.25, 0.35 * wave(t, 3))]
    return p


def pounce(t):
    p = Pose()
    gather = 1.0 - ease(0.1, 0.3, t)
    air = ease(0.2, 0.42, t) * (1.0 - ease(0.55, 0.7, t))
    land = ease(0.55, 0.7, t) * (1.0 - ease(0.85, 1.0, t))
    p.hips = Vector((0.0, 0.0, -0.95 * gather + 0.55 * air - 0.55 * land))
    p.bend("Hips", pitch=0.25 * air - 0.15 * land).bend("Spine", pitch=0.08 * gather - 0.15 * land)
    p.bend("Neck", pitch=-0.5 * gather + 0.1 * air - 0.35 * land).bend("Head", pitch=0.45 * gather + 0.2 * land)
    reach = air + land
    for k in ("FL", "FR"):
        p.feet[k] = NEUTRAL[k] + Vector((0.45 * gather + 1.1 * reach, 0, 0.55 * air))
        p.paw[k] = 0.6 * air
    for k in ("HL", "HR"):
        p.feet[k] = NEUTRAL[k] + Vector((0.55 * gather - 0.6 * air + 0.3 * land, 0, 0.35 * air))
        p.paw[k] = -0.5 * air
    p.elbows_up = 1.4 * gather
    p.tail = [(1.6 - 0.3 * air, 0.0), (0.0, 0.0), (-0.1 * air, 0.0), (-0.2, 0.0)]
    return p


def hiss(t):
    p = Pose()
    p.planted = True
    tr = wave(t, 6)
    p.hips = Vector((0.1, 0, 0.25))
    p.bend("Hips", pitch=0.42).bend("Spine", pitch=-0.8, roll=0.01 * tr)
    p.bend("Neck", pitch=-0.05).bend("Head", pitch=0.15)
    for k in ("FL", "FR"):
        p.feet[k] = NEUTRAL[k] + Vector((-0.3, 0, 0))
    for k in ("HL", "HR"):
        p.feet[k] = NEUTRAL[k] + Vector((0.55, 0, 0))
    p.tail = [(-0.35, 0.0), (0.0, 0.02 * tr), (0.25, 0.0), (0.5, 0.0)]
    return p


def startle(t):
    p = Pose()
    dip = ease(0.0, 0.12, t) * (1.0 - ease(0.12, 0.25, t))
    air = ease(0.15, 0.3, t) * (1.0 - ease(0.42, 0.58, t))
    land = ease(0.5, 0.62, t) * (1.0 - ease(0.62, 0.9, t))
    p.hips = Vector((0, 0, -0.35 * dip + 0.85 * air - 0.25 * land))
    p.bend("Hips", pitch=0.15 * air).bend("Spine", pitch=-0.35 * air).bend("Neck", pitch=-0.15 * air)
    for k in NEUTRAL:
        p.feet[k] = NEUTRAL[k] + Vector((0, 0, 0.62 * air))
        p.paw[k] = (0.5 if k[0] == "F" else -0.3) * air
    p.tail = [(-0.3 * air, 0.0), (0.0, 0.0), (0.0, 0.0), (0.0, 0.0)]
    return p


def stretch(t):
    p = Pose()
    k = ease(0.0, 0.3, t) * (1.0 - ease(0.62, 0.95, t))
    p.hips = Vector((-0.15 * k, 0, -0.1 * k))
    p.bend("Hips", pitch=-0.12 * k).bend("Spine", pitch=-0.42 * k).bend("Neck", pitch=0.35 * k)
    p.bend("Head", pitch=-0.15 * k)
    for f in ("FL", "FR"):
        p.feet[f] = NEUTRAL[f] + Vector((1.05 * k, 0, 0))
    p.tail = [(-0.1 * k, 0.0), (0.0, 0.0), (0.0, 0.0), (0.0, 0.0)]
    return p


# name, frames, pose, loops
CLIPS = [
    ("Trot", 24, trot, True), ("Run", 24, run, True), ("Sit", 48, sit, True), ("Loaf", 48, loaf, True),
    ("Sleep", 72, sleep, True), ("Groom", 48, groom, True), ("Stalk", 48, stalk, True),
    ("Crouch", 24, crouch, True), ("Pounce", 24, pounce, False), ("Hiss", 24, hiss, True),
    ("Startle", 18, startle, False), ("Stretch", 48, stretch, False),
]


def new_action(arm, name, loops):
    act = bpy.data.actions.new(name + ("-loop" if loops else ""))
    act.use_fake_user = True
    arm.animation_data.action = act
    return act


def close_action(act, frames):
    act.use_frame_range = True
    act.frame_start, act.frame_end = 0, frames


def baked_clip(arm, name, poses):
    act = new_action(arm, name, True)
    for f, pose in enumerate(poses):
        for n, m in pose.items():
            pb = arm.pose.bones[n]
            pb.rotation_mode = "QUATERNION"
            loc, rot, _s = m.decompose()
            pb.location, pb.rotation_quaternion, pb.scale = loc, rot, (1, 1, 1)
            pb.keyframe_insert("rotation_quaternion", frame=f, group=n)
            pb.keyframe_insert("location", frame=f, group=n)
    close_action(act, len(poses) - 1)
    return act


def posed_clip(arm, rig, name, frames, fn, loops):
    act = new_action(arm, name, loops)
    for f in range(frames + 1):
        pose_rig(rig, fn(f / frames))
        rig.keys(f)
    close_action(act, frames)
    return act


# ------------------------------------------------------------------ checks, renders, export


def mesh_low(mesh):
    ev = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
    me = ev.to_mesh()
    z = min(v.co.z for v in me.vertices)
    ev.to_mesh_clear()
    return z


def walk_speed(arm, act):
    """Model units a second the planted paws of a clip move back (its ground speed at rate 1)."""
    arm.animation_data.action = act
    prev, speeds = None, []
    for f in range(int(act.frame_range[0]), int(act.frame_range[1]) + 1):
        bpy.context.scene.frame_set(f)
        now = {k: arm.pose.bones[CHAIN[k][2]].head.copy() for k in CHAIN}
        if prev is not None:
            for k in CHAIN:
                if now[k].z < 0.08 and prev[k].z < 0.08:
                    speeds.append((prev[k].x - now[k].x) * FPS)
        prev = now
    speeds.sort()
    return speeds[len(speeds) // 2] if speeds else 0.0


def report(arm, mesh, clips):
    for name, act in clips.items():
        arm.animation_data.action = act
        lows = []
        for f in range(int(act.frame_range[0]), int(act.frame_range[1]) + 1, 3):
            bpy.context.scene.frame_set(f)
            lows.append(mesh_low(mesh))
        print("CLIP %-8s %3d frames, lowest point %.3f" % (name, int(act.frame_range[1]), min(lows)))
    for name in ("Walk", "Trot", "Run", "Stalk"):
        print("SPEED %-6s %.3f units/s at rate 1" % (name, walk_speed(arm, clips[name])))


def renders(arm, clips, folder):
    os.makedirs(folder, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.color_type = "VERTEX"
    scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = 260, 195, 100
    cam = bpy.data.objects.new("ReviewCam", bpy.data.cameras.new("ReviewCam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 7.0
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, 12.0, 1.6)
    cam.rotation_euler = (Vector((0, 0, 1.6)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    for name, act in clips.items():
        arm.animation_data.action = act
        end = int(act.frame_range[1])
        for f in (0, end // 3, 2 * end // 3):
            scene.frame_set(f)
            scene.render.filepath = os.path.join(folder, "%s_%02d.png" % (name, f))
            bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)


def face_plus_z(arm, mesh):
    """Turns the cat from +X to Blender -Y, which is +Z in glTF (the dogs' facing)."""
    arm.animation_data.action = None
    bpy.ops.object.select_all(action="DESELECT")
    arm.rotation_euler = (0.0, 0.0, -math.pi / 2)
    arm.select_set(True)
    mesh.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)


def export(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=False,
        export_yup=True,
        export_apply=False,
        export_texcoords=True,
        export_normals=True,
        export_vertex_color="ACTIVE",
        export_materials="EXPORT",
        export_skins=True,
        export_def_bones=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_force_sampling=True,
        export_frame_step=1,
        export_optimize_animation_size=False,
        export_morph=False,
        export_cameras=False,
        export_lights=False,
    )


def main():
    opts = args()
    bpy.ops.wm.open_mainfile(filepath=SRC)
    bpy.context.scene.render.fps = FPS
    arm = bpy.data.objects["CatArmature"]
    mesh = bpy.data.objects["Cat"]
    arm.name, mesh.name = "CatRig", "CatBody"
    rename(arm, mesh)
    deform = [b.name for b in arm.data.bones if b.use_deform and b.name not in IK_BONES]
    baked = {"Idle": bake(arm, "Idle", deform), "Walk": bake(arm, "Walking", deform)}
    strip_ik(arm)
    smooth(mesh)
    write_fields(mesh, arm)
    one_material(mesh)
    clips = {name: baked_clip(arm, name, poses) for name, poses in baked.items()}
    rig = Rig(arm, deform)
    for name, frames, fn, loops in CLIPS:
        clips[name] = posed_clip(arm, rig, name, frames, fn, loops)
    report(arm, mesh, clips)
    if opts["renders"]:
        renders(arm, clips, opts["renders"])
    for ob in list(bpy.data.objects):
        if ob not in (arm, mesh):
            bpy.data.objects.remove(ob)
    face_plus_z(arm, mesh)
    export(opts["out"])
    print("EXPORTED", opts["out"], len(mesh.data.vertices), "vertices")


main()
