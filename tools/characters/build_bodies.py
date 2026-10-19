"""Build the character bodies from the cached Rocketbox sources (headless Blender).

usage: blender --background --factory-startup --python tools/characters/build_bodies.py -- \
           <cache> <out> [--only Name,Name] [--no-lod] [--roster-only]

  <cache>  ~/.cache/gridfall/characters (fetch.py); reports go to <cache>/build/reports/
  <out>    models/characters of this repo

For every roster avatar (manifest.json) it writes, under <out>/bodies/:
  <Name>.glb             skinned body on the clean rig (rb_rig.py), metric, feet at y = 0, facing +Z,
                         at most 4 influences, no animation, no images (materials are external)
  <Name>_lod1.glb        far LOD: posed mid-stride (walk frame 8), <= 1,500 tris, body + head only, no skin
  tex/<Name>_<part>_{color,normal}.jpg, tex/<Name>_opacity_color.png, tex/<Name>_lod_{body,head}.jpg
  mat/<Name>_<part>.tres Godot StandardMaterial3D per surface (the .glb.import maps them by name)
and the .import files for all of them (BoneMap retarget, external materials, VRAM-compressed textures).
Finally it merges every report into <out>/roster.json with roster_rules.json.

The Blender flatpak cannot read /tmp: keep <cache> and <out> under $HOME.
"""

import json
import math
import os
import sys
import time

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rb_rig  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RES = "res://models/characters/"
LOD_TRIS = 1500
BODY_TRIS = 9000
WALK_SRC = {"m": "all_animations_max_motextr_xy/m_walk_neutral_02.max.fbx", "f": "all_animations_max_motextr_xy/f_walk_neutral_01.max.fbx"}
LOD_FRAME = 8


def tex_sizes(group: str) -> dict:
	"""Map size per part kind: the hero gets 1K everywhere; residents body 512, head 1K, rest 512."""
	if group == "hero":
		return {"head": 1024, "default": 1024}
	return {"head": 1024, "default": 512}


def find_tga(tex_dir: str, rid: str, part: str, kind: str) -> str:
	"""<id>_<part>_<kind>[_suffix].tga (handles f110_head_color_a and m154_body_color_blue)."""
	exact = os.path.join(tex_dir, "%s_%s_%s.tga" % (rid, part, kind))
	if os.path.isfile(exact):
		return exact
	stem = "%s_%s_%s_" % (rid, part, kind)
	hits = sorted(f for f in os.listdir(tex_dir) if f.startswith(stem) and f.endswith(".tga"))
	return os.path.join(tex_dir, hits[0]) if hits else ""


def save_tex(src: str, dst: str, px: int, kind: str) -> int:
	"""Downscales a TGA and saves it as JPEG (colour q88, normal q90) or PNG (opacity). Returns bytes."""
	img = bpy.data.images.load(src)
	img.colorspace_settings.name = "Non-Color" if kind == "normal" else "sRGB"
	if img.size[0] != px or img.size[1] != px:
		img.scale(px, px)
	os.makedirs(os.path.dirname(dst), exist_ok=True)
	if kind == "opacity":
		# Transparent texels get the mean opaque colour: no dark fringes under mip filtering, and a
		# far smaller PNG than the original noise under alpha 0.
		px_arr = np.empty(px * px * 4, dtype=np.float32)
		img.pixels.foreach_get(px_arr)
		a = px_arr.reshape(-1, 4)
		solid = a[:, 3] > 0.5
		if solid.any():
			mean = a[solid, :3].mean(axis=0)
			a[a[:, 3] < 0.02, :3] = mean
		a[:] = np.round(a * 255.0) / 255.0
		img.pixels.foreach_set(a.ravel())
		img.file_format = "PNG"
		img.save(filepath=dst)
	else:
		img.file_format = "JPEG"
		img.save(filepath=dst, quality=90 if kind == "normal" else 88)
	bpy.data.images.remove(img)
	return os.path.getsize(dst)


def write_texture_import(path: str, normal: bool) -> None:
	"""VRAM-compressed, mipmapped texture import (G2's settings for model textures)."""
	with open(path + ".import", "w") as f:
		f.write('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n[params]\n\n')
		f.write("compress/mode=2\ncompress/high_quality=false\ncompress/lossy_quality=0.7\n")
		f.write("compress/uastc_level=0\ncompress/rdo_quality_loss=0.0\ncompress/hdr_compression=1\n")
		f.write("compress/normal_map=%d\ncompress/channel_pack=0\nmipmaps/generate=true\nmipmaps/limit=-1\n" % (1 if normal else 2))
		f.write('roughness/mode=0\nroughness/src_normal=""\n')
		f.write("process/channel_remap/red=0\nprocess/channel_remap/green=1\nprocess/channel_remap/blue=2\nprocess/channel_remap/alpha=3\n")
		f.write("process/fix_alpha_border=true\nprocess/premult_alpha=false\nprocess/normal_map_invert_y=false\n")
		f.write("process/hdr_as_srgb=false\nprocess/hdr_clamp_exposure=false\nprocess/size_limit=0\ndetect_3d/compress_to=0\n")


def write_material(path: str, name: str, color: str, normal: str, opacity: bool, flat=None, roughness: float = 0.7, specular: float = 0.5) -> None:
	"""A Godot StandardMaterial3D .tres (paths are res:// texture paths or "")."""
	ext = [p for p in (color, normal) if p]
	lines = ['[gd_resource type="StandardMaterial3D" load_steps=%d format=3]\n' % (len(ext) + 1)]
	for i, p in enumerate(ext, 1):
		lines.append('[ext_resource type="Texture2D" path="%s" id="%d"]' % (p, i))
	lines.append("\n[resource]")
	lines.append('resource_name = "%s"' % name)
	if opacity:
		lines += ["transparency = 2", "alpha_scissor_threshold = 0.5", "alpha_antialiasing_mode = 1", "alpha_antialiasing_edge = 0.3", "cull_mode = 2"]
	if color:
		lines.append('albedo_texture = ExtResource("1")')
	if flat is not None:
		lines.append("albedo_color = Color(%.3f, %.3f, %.3f, 1)" % tuple(flat))
	lines.append("roughness = %.2f" % roughness)
	if specular != 0.5:
		lines.append("metallic_specular = %.2f" % specular)
	if normal:
		lines.append("normal_enabled = true")
		lines.append('normal_texture = ExtResource("%d")' % (2 if color else 1))
	lines.append("texture_filter = 5")
	with open(path, "w") as f:
		f.write("\n".join(lines) + "\n")


def write_scene_import(path: str, materials: dict, skinned: bool) -> None:
	"""The .glb.import: external materials by name and, for skinned bodies, the Rocketbox BoneMap
	retarget onto %GeneralSkeleton (HC owns these settings; G2 leaves them alone)."""
	sub = []
	if materials:
		mats = ",\n".join('"%s": {\n"use_external/enabled": true,\n"use_external/path": "%s"\n}' % (k, v) for k, v in sorted(materials.items()))
		sub.append('"materials": {\n%s\n}' % mats)
	if skinned:
		sub.append('"nodes": {\n"PATH:Armature/Skeleton3D": {\n%s\n}\n}' % RETARGET_RB)
	with open(path + ".import", "w") as f:
		f.write('[remap]\n\nimporter="scene"\nimporter_version=1\ntype="PackedScene"\n\n[params]\n\n')
		f.write(SCENE_PARAMS % ("true" if skinned else "false"))
		f.write("_subresources={\n%s\n}\n" % ",\n".join(sub))
		f.write("gltf/naming_version=2\ngltf/embedded_image_handling=0\n")


SCENE_PARAMS = """nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
mesh_library/use_node_names_as_mesh_names=false
array_mesh/deduplicate_surfaces=true
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=true
meshes/generate_lods=%s
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=false
skins/use_named_skins=true
animation/import=false
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
"""

RETARGET_RB = """"retarget/bone_map": Resource("res://models/characters/bonemap_rocketbox.tres"),
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


def mesh_stats(obj) -> tuple:
	dg = bpy.context.evaluated_depsgraph_get()
	ev = obj.evaluated_get(dg)
	me = ev.to_mesh()
	me.calc_loop_triangles()
	tris = len(me.loop_triangles)
	zs = [(obj.matrix_world @ v.co).z for v in me.vertices]
	ev.to_mesh_clear()
	return tris, min(zs), max(zs)


def drop_parts(obj, parts: set) -> None:
	"""Deletes the faces of the named parts (by material slot) and their slots."""
	me = obj.data
	idx = [i for i, s in enumerate(obj.material_slots) if s.material and part_of(s.material.name)[1] in parts]
	if not idx:
		return
	bm = bmesh.new()
	bm.from_mesh(me)
	bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.material_index in idx], context="FACES")
	bm.to_mesh(me)
	bm.free()
	for i in sorted(idx, reverse=True):
		obj.active_material_index = i
		bpy.context.view_layer.objects.active = obj
		bpy.ops.object.material_slot_remove()
	# Loose vertices left behind would still be skinned and exported.
	bm = bmesh.new()
	bm.from_mesh(me)
	bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
	bm.to_mesh(me)
	bm.free()


def part_of(mat_name: str) -> tuple:
	"""('m011', 'body') from 'm011_body' (Blender may add '.001')."""
	base = mat_name.split(".")[0]
	rid, _, part = base.partition("_")
	return rid, part


def build_one(name: str, info: dict, cache: str, out: str, rules: dict, lod: bool) -> dict:
	t0 = time.time()
	rb_rig.reset()
	root = os.path.join(cache, "rocketbox", "Assets", "Avatars")
	sub = "Adults" if os.path.isdir(os.path.join(root, "Adults", name)) else "Professions"
	adir = os.path.join(root, sub, name)
	src = rb_rig.import_fbx(os.path.join(adir, "Export", name + ".fbx"))
	src.animation_data_clear()
	meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
	if len(meshes) != 1:
		raise RuntimeError("%s: expected one mesh, found %d" % (name, len(meshes)))
	body = meshes[0]
	arm, _parents = rb_rig.build_rig(src)
	# Bake the mesh into world metres and move it onto the clean rig.
	mw = body.matrix_world.copy()
	body.parent = None
	body.data.transform(mw)
	body.matrix_world = Matrix.Identity(4)
	body.parent = arm
	for m in body.modifiers:
		if m.type == "ARMATURE":
			m.object = arm
	for o in list(bpy.context.scene.objects):
		if o not in (arm, body):
			bpy.data.objects.remove(o, do_unlink=True)
	body.name = "Body"
	for img in list(bpy.data.images):
		bpy.data.images.remove(img)
	drop_parts(body, set(rules["drop_parts"]))
	tris = mesh_stats(body)[0]
	if tris > BODY_TRIS:
		# A few professions and Female_Adult_04 come in just over budget: a light collapse, first in the
		# stack (before the armature), keeps the weights and UVs.
		dec = body.modifiers.new("Decimate", "DECIMATE")
		dec.decimate_type = "COLLAPSE"
		dec.ratio = (BODY_TRIS - 120) / tris
		dec.use_collapse_triangulate = True
		bpy.context.view_layer.objects.active = body
		bpy.ops.object.modifier_move_to_index(modifier=dec.name, index=0)
		bpy.ops.object.modifier_apply(modifier=dec.name)
	# At most 4 influences per vertex, renormalised.
	bpy.context.view_layer.objects.active = body
	body.select_set(True)
	bpy.ops.object.vertex_group_limit_total(group_select_mode="ALL", limit=4)
	bpy.ops.object.vertex_group_normalize_all(group_select_mode="ALL", lock_active=False)

	rid = info["id"]
	tex_dir = os.path.join(adir, "Textures")
	sizes = tex_sizes(info["group"])
	bdir = os.path.join(out, "bodies")
	tdir = os.path.join(bdir, "tex")
	mdir = os.path.join(bdir, "mat")
	os.makedirs(mdir, exist_ok=True)
	mats = {}
	parts = []
	tex_bytes = 0
	for slot in body.material_slots:
		mrid, part = part_of(slot.material.name)
		slot.material.name = "%s_%s" % (mrid, part)
		parts.append(part)
		px = sizes.get(part, sizes["default"])
		opacity = part.endswith("opacity")
		res = {}
		for kind in ("color", "normal"):
			src_tga = find_tga(tex_dir, rid, part, kind)
			if not src_tga:
				continue
			k = "opacity" if (opacity and kind == "color") else kind
			ext = "png" if k == "opacity" else "jpg"
			fn = "%s_%s_%s.%s" % (name, part, kind, ext)
			tex_bytes += save_tex(src_tga, os.path.join(tdir, fn), px, k)
			write_texture_import(os.path.join(tdir, fn), kind == "normal")
			res[kind] = RES + "bodies/tex/" + fn
		if "color" not in res and "normal" not in res:
			raise RuntimeError("%s: no textures for part %s" % (name, part))
		flat = None if "color" in res else (0.05, 0.05, 0.05)
		mpath = os.path.join(mdir, "%s_%s.tres" % (name, part))
		rough, spec = (0.35, 0.5) if flat else (0.7, 0.5)
		if part == "opacity":
			# Hair cards: seen edge-on, default specular turns them into grey sky-coloured streaks.
			rough, spec = 0.85, 0.15
		write_material(mpath, slot.material.name, res.get("color", ""), res.get("normal", ""), opacity, flat, rough, spec)
		mats[slot.material.name] = RES + "bodies/mat/%s_%s.tres" % (name, part)

	tris, zmin, zmax = mesh_stats(body)
	glb = os.path.join(bdir, name + ".glb")
	bpy.ops.object.select_all(action="DESELECT")
	export_glb(glb, animations=False)
	write_scene_import(glb, mats, skinned=True)
	hip = arm.data.bones[rb_rig.BIP].head_local.z
	rep = {"name": name, "group": info["group"], "gender": info["gender"], "id": rid, "parts": parts,
		"rest_height_m": round(zmax - zmin, 4), "feet_m": round(zmin, 4), "hip_m": round(hip, 4),
		"tris": tris, "surfaces": len(body.material_slots), "bytes": os.path.getsize(glb) + tex_bytes,
		"path": RES + "bodies/%s.glb" % name}
	if lod:
		rep["lod1"] = build_lod(name, info, arm, body, cache, out)
	rep["seconds"] = round(time.time() - t0, 1)
	return rep


def build_lod(name: str, info: dict, arm, body, cache: str, out: str) -> dict:
	"""Static far LOD posed mid-stride: body and head surfaces only, decimated, 256 maps, no skin."""
	src = rb_rig.import_fbx(os.path.join(cache, "rocketbox", "Assets", "Animations", WALK_SRC[info["gender"]]))
	f0 = int(round(src.animation_data.action.frame_range[0]))
	tgt_rest = {b.name: b.matrix_local.copy() for b in arm.data.bones}
	parents = {b.name: b.parent.name for b in arm.data.bones if b.parent}
	order = [n for n in rb_rig.deform_names(src) if n in tgt_rest]
	w = rb_rig.transfer(rb_rig.sample_worlds(src, f0 + LOD_FRAME), tgt_rest, parents, order)
	# In place: the COM over the origin, travel removed.
	off = Matrix.Translation((-w[rb_rig.BIP].translation.x, -w[rb_rig.BIP].translation.y, 0.0))
	w = {k: off @ v for k, v in w.items()}
	w[rb_rig.ROOT] = tgt_rest[rb_rig.ROOT]
	rb_rig.set_pose(arm, rb_rig.basis_from_worlds(arm, w))
	for o in list(bpy.context.scene.objects):
		if o not in (arm, body):
			bpy.data.objects.remove(o, do_unlink=True)
	lod = body.copy()
	lod.data = body.data.copy()
	bpy.context.scene.collection.objects.link(lod)
	bpy.ops.object.select_all(action="DESELECT")
	bpy.context.view_layer.objects.active = lod
	lod.select_set(True)
	for m in list(lod.modifiers):
		bpy.ops.object.modifier_apply(modifier=m.name)
	lod.parent = None
	lod.matrix_world = Matrix.Identity(4)
	lod.vertex_groups.clear()
	keep = {"body", "head"}
	drop_parts(lod, {part_of(s.material.name)[1] for s in lod.material_slots} - keep)
	tris = mesh_stats(lod)[0]
	ratio = min(1.0, (LOD_TRIS - 60) / max(tris, 1))
	for _ in range(4):
		dec = lod.modifiers.new("Decimate", "DECIMATE")
		dec.decimate_type = "COLLAPSE"
		dec.ratio = ratio
		dec.use_collapse_triangulate = True
		bpy.ops.object.modifier_apply(modifier=dec.name)
		tris = mesh_stats(lod)[0]
		if tris <= LOD_TRIS:
			break
		ratio = (LOD_TRIS - 60) / tris
	# The LOD sits on the ground in its pose.
	zmin = mesh_stats(lod)[1]
	lod.data.transform(Matrix.Translation((0, 0, -zmin)))
	bdir = os.path.join(out, "bodies")
	mats = {}
	tex_bytes = 0
	tex_dir_root = os.path.join(cache, "rocketbox", "Assets", "Avatars")
	sub = "Adults" if os.path.isdir(os.path.join(tex_dir_root, "Adults", name)) else "Professions"
	tex_dir = os.path.join(tex_dir_root, sub, name, "Textures")
	for slot in lod.material_slots:
		rid, part = part_of(slot.material.name)
		m = slot.material.copy()
		m.name = "%s_%s_lod" % (rid, part)
		slot.material = m
		fn = "%s_lod_%s.jpg" % (name, part)
		tex_bytes += save_tex(find_tga(tex_dir, rid, part, "color"), os.path.join(bdir, "tex", fn), 256, "color")
		write_texture_import(os.path.join(bdir, "tex", fn), False)
		write_material(os.path.join(bdir, "mat", "%s_lod_%s.tres" % (name, part)), m.name, RES + "bodies/tex/" + fn, "", False, None, 0.8)
		mats[m.name] = RES + "bodies/mat/%s_lod_%s.tres" % (name, part)
	bpy.data.objects.remove(body, do_unlink=True)
	bpy.data.objects.remove(arm, do_unlink=True)
	lod.name = "Body_lod1"
	glb = os.path.join(bdir, name + "_lod1.glb")
	export_glb(glb, animations=False)
	write_scene_import(glb, mats, skinned=False)
	return {"tris": tris, "surfaces": len(lod.material_slots), "bytes": os.path.getsize(glb) + tex_bytes,
		"path": RES + "bodies/%s_lod1.glb" % name}


def export_glb(path: str, animations: bool) -> None:
	bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", export_image_format="NONE",
		export_materials="EXPORT", export_animations=animations, export_skins=True, export_influence_nb=4,
		export_morph=False, export_yup=True, export_apply=False, export_tangents=False, export_extras=False,
		export_cameras=False, export_lights=False, export_def_bones=False, export_rest_position_armature=True,
		export_texcoords=True, export_normals=True, export_vertex_color="NONE")


def write_roster(out: str, man: dict, rules: dict, reports: dict) -> None:
	bodies = {}
	for name, info in man["avatars"].items():
		if name in reports:
			bodies[name] = reports[name]
	groups = {}
	for name, info in man["avatars"].items():
		groups.setdefault(info["group"], []).append(name)
	residents = {n: i for n, i in man["avatars"].items() if i["group"] != "hero"}
	job_pools = {}
	for group, jobs in rules["group_jobs"].items():
		for job in jobs:
			job_pools[job] = rules["job_refine"].get(job, [n for n, i in residents.items() if i["group"] == group])
	casual = {g: [n for n, i in residents.items() if i["group"] == "casual" and i["gender"] == g] for g in ("m", "f")}
	roster = {
		"version": 1,
		"note": "HC roster (docs/fp/slices/HC-characters.md). Skeletons are metric: CharacterRoot.scale = WS.M * h_target / rest_height_m. Pick a resident body from job_pools[job] filtered by gender, else casual_pools[gender], index crc32(resident_id) % n; name_gender misses fall back to crc32(id) & 1.",
		"heroes": rules["heroes"],
		"bodies": bodies,
		"groups": groups,
		"job_pools": job_pools,
		"casual_pools": casual,
		"ambient_weights": rules["ambient_weights"],
		"uniform_groups": ["police", "medical", "fire", "trades", "service"],
		"height": rules["height"],
		"name_gender": rules["name_gender"],
	}
	old = os.path.join(out, "roster.json")
	if os.path.isfile(old):
		with open(old) as f:
			prev = json.load(f)
		# Keys the Godot library builder adds (rig facts read after import) survive a rebuild.
		for k in ("rigs",):
			if k in prev:
				roster[k] = prev[k]
	with open(old, "w") as f:
		json.dump(roster, f, indent=1, sort_keys=False)
		f.write("\n")


def main() -> None:
	argv = sys.argv[sys.argv.index("--") + 1:]
	cache, out = os.path.abspath(argv[0]), os.path.abspath(argv[1])
	only = []
	if "--only" in argv:
		only = [s for s in argv[argv.index("--only") + 1].split(",") if s]
	lod = "--no-lod" not in argv
	with open(os.path.join(HERE, "manifest.json")) as f:
		man = json.load(f)
	with open(os.path.join(HERE, "roster_rules.json")) as f:
		rules = json.load(f)
	rep_dir = os.path.join(cache, "build", "reports")
	os.makedirs(rep_dir, exist_ok=True)
	if "--roster-only" not in argv:
		names = only or list(man["avatars"])
		for name in names:
			rep = build_one(name, man["avatars"][name], cache, out, rules, lod)
			with open(os.path.join(rep_dir, name + ".json"), "w") as f:
				json.dump(rep, f, indent=1)
			print("@@BODY " + json.dumps(rep), flush=True)
	reports = {}
	for fn in sorted(os.listdir(rep_dir)):
		with open(os.path.join(rep_dir, fn)) as f:
			r = json.load(f)
		reports[r["name"]] = r
	write_roster(out, man, rules, reports)
	print("@@ROSTER %d bodies" % len(reports))


main()
