extends SceneTree
## Slice HC acceptance (docs/fp/slices/HC-characters.md): roster bodies, far LODs, the shared animation
## libraries, retarget sanity, root motion, head-look axes, assignment data, licences and provenance.
## Headless; prints FP_CHARACTERS_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const REQUIRED_BONES := ["Root", "Hips", "Spine", "Chest", "Neck", "Head", "LeftUpperLeg", "LeftLowerLeg",
	"LeftFoot", "RightFoot", "LeftHand", "RightHand"]
const FOOT_BONES := ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]
const LOOP_TRAVEL := ["walk", "walk_fast", "run", "run_fast", "crouch_walk", "carry"]
const HEEL_STRIKE := ["walk", "run", "run_fast"]
const FPS := 30.0
## roster.json rest_height_m is the stature to the skull top: eye height times this (build_bodies.py).
const STATURE_PER_EYE := 1.0647
const MANIFEST := "res://tools/characters/manifest.json"
const QUATERNIUS := "res://tools/characters/quaternius.json"
const LICENCES := ["rocketbox-MIT.txt", "quaternius-UAL1-License.txt", "quaternius-UAL2-License.txt"]
## Biped's Hips is the COM node: it rides at 0.46-0.48 of the standing height in a walk (measured on
## both heroes), a little under the 0.48 the plan assumed. The band still catches the two failure modes
## (hips doubled by a wrong BoneMap, or sunk into the ground).
const WALK_HIPS := Vector2(0.44, 0.56)
## Seated hips: 0.32 of the height on the male hero, 0.345 on the female (Rocketbox women stand with
## higher hips, 0.52 against 0.49), so the plan's 0.33 becomes 0.36; standing is 0.49-0.52.
const SIT_HIPS := 0.36

var fails: Array[String] = []
var roster: Dictionary = {}
var libs: Dictionary = {}
var clip_info: Dictionary = {}


func _initialize() -> void:
	roster = _json(AP.CHAR_ROSTER)
	K.check(fails, not roster.is_empty(), "roster.json loads")
	var report := _json(AP.CHARACTERS_DIR + "anim/clips.json")
	clip_info = report.get("clips", {})
	K.check(fails, not clip_info.is_empty(), "anim/clips.json lists the clips")
	for g: String in ["m", "f"]:
		libs[g] = load(AP.CHAR_LIB_M if g == "m" else AP.CHAR_LIB_F) as AnimationLibrary
		K.check(fails, libs[g] != null, "lib_%s loads" % g)
	if roster.is_empty() or libs["m"] == null or libs["f"] == null:
		K.finish(self, "FP_CHARACTERS_TEST", fails)
		return
	_check_libraries()
	_check_roster()
	_check_licences()
	var bodies: Dictionary = roster.get("bodies", {})
	K.check(fails, bodies.has("Male_Adult_06") and bodies.has("Female_Adult_04"), "both heroes are in the roster")
	K.check(fails, AP.HERO_M.ends_with("/Male_Adult_06.glb") and AP.HERO_F.ends_with("/Female_Adult_04.glb"), "AP hero paths name the roster heroes")
	for name: String in bodies:
		_check_body(name, bodies[name])
	print("checked %d bodies" % bodies.size())
	K.finish(self, "FP_CHARACTERS_TEST", fails)


# --- Libraries -----------------------------------------------------------------------------------

func _check_libraries() -> void:
	for g: String in ["m", "f"]:
		var lib: AnimationLibrary = libs[g]
		var missing: Array[String] = []
		for n: String in AP.PERSON_ANIMS + AP.PERSON_TPS_ANIMS:
			if not lib.has_animation(StringName(n)):
				missing.append(n)
		K.check(fails, missing.is_empty(), "lib_%s holds every PERSON_ANIMS and PERSON_TPS_ANIMS clip %s" % [g, missing])
		var bad_loop: Array[String] = []
		var no_meta: Array[String] = []
		for n: StringName in lib.get_animation_list():
			var a := lib.get_animation(n)
			var info: Dictionary = clip_info.get(String(n), {})
			var want_loop: bool = (info.get(g, info.get("u", {})) as Dictionary).get("loop", false)
			if String(n) in AP.PERSON_LOOPING:
				want_loop = true
			if (a.loop_mode == Animation.LOOP_LINEAR) != want_loop:
				bad_loop.append(String(n))
			if not a.has_meta("speed_mps") or not a.has_meta("speed_ref_hip_m") or not a.has_meta("loop"):
				no_meta.append(String(n))
		K.check(fails, bad_loop.is_empty(), "lib_%s: loops are LOOP_LINEAR, one-shots LOOP_NONE %s" % [g, bad_loop])
		K.check(fails, no_meta.is_empty(), "lib_%s: every clip has speed_mps, speed_ref_hip_m and loop metas %s" % [g, no_meta])
	var shared := 0
	for n: StringName in libs["m"].get_animation_list():
		if libs["f"].has_animation(n) and libs["m"].get_animation(n) == libs["f"].get_animation(n):
			shared += 1
			K.check(fails, libs["m"].get_animation(n).resource_path.get_file().begins_with("u_"), "only UAL clips are shared: %s" % n)
	K.check(fails, shared >= 16, "the UAL clips are shared by both libraries (%d)" % shared)


# --- Bodies --------------------------------------------------------------------------------------

func _check_body(name: String, info: Dictionary) -> void:
	var path: String = AP.CHAR_BODIES_DIR + name + ".glb"
	var ps := AP.load_scene(path)
	K.check(fails, ps != null, "%s loads through AP.load_scene" % name)
	if ps == null:
		return
	var holder := Node3D.new()
	holder.name = "CharacterRoot"
	root.add_child(holder)
	var body := ps.instantiate() as Node3D
	holder.add_child(body)
	var sk := body.get_node_or_null("%GeneralSkeleton") as Skeleton3D
	K.check(fails, sk != null, "%s has %%GeneralSkeleton" % name)
	if sk == null:
		holder.free()
		return
	var missing: Array[String] = []
	for b: String in REQUIRED_BONES:
		if sk.find_bone(b) < 0:
			missing.append(b)
	K.check(fails, missing.is_empty(), "%s has the humanoid bones %s" % [name, missing])
	var meshes := body.find_children("*", "MeshInstance3D", true, false)
	var skinned: Array[MeshInstance3D] = []
	for m: Node in meshes:
		if (m as MeshInstance3D).skin != null:
			skinned.append(m as MeshInstance3D)
	K.check(fails, skinned.size() == 1, "%s has one skinned mesh (%d)" % [name, skinned.size()])
	if skinned.size() == 1:
		var mesh := skinned[0].mesh
		var tris := _tris(mesh)
		K.check(fails, mesh.get_surface_count() >= 1 and mesh.get_surface_count() <= 6 and tris <= 9000, "%s: %d surfaces, %d tris (1-6, <= 9000)" % [name, mesh.get_surface_count(), tris])
		var h_rest: float = info.get("rest_height_m", 0.0)
		var eye: float = info.get("eye_m", 0.0)
		var head := sk.get_bone_global_rest(sk.find_bone("Head")).origin.y
		var top := mesh.get_aabb().end.y
		K.check(fails, absf(h_rest - eye * STATURE_PER_EYE) < 0.001 and h_rest > head + 0.1 and h_rest <= top + 0.005, "%s: rest_height_m %.3f is the stature (eye %.3f; head bone %.3f, mesh top %.3f)" % [name, h_rest, eye, head, top])
		K.check(fails, absf(mesh.get_aabb().size.y - float(info.get("aabb_height_m", 0.0))) < 0.01, "%s: aabb_height_m matches the mesh (%.3f)" % [name, mesh.get_aabb().size.y])
		# CharacterRoot at the shortest and tallest resident jitter (heroes use 1.0).
		var h_target := 1.75 * (1.0 if info.get("gender", "m") == "m" else 0.95)
		for jitter: float in [0.97, 1.03]:
			holder.scale = Vector3.ONE * WS.M * h_target * jitter / maxf(h_rest, 0.01)
			var aabb_h := mesh.get_aabb().size.y * holder.scale.y
			K.check(fails, aabb_h >= 0.08 and aabb_h <= 0.095, "%s: height with CharacterRoot scaling %.4f u in [0.08, 0.095] (jitter %.2f)" % [name, aabb_h, jitter])
	K.check(fails, absf(sk.motion_scale - float(info.get("hip_m", 0.0))) < 0.005, "%s: hip_m %.3f matches motion_scale %.3f" % [name, info.get("hip_m", 0.0), sk.motion_scale])
	_check_look_axis(name, sk)
	_check_lod(name)
	var g: String = info.get("gender", "m")
	_check_tracks(name, sk, libs[g])
	_check_motion(name, body, sk, libs[g])
	holder.free()


func _check_lod(name: String) -> void:
	var ps := AP.load_scene(AP.CHAR_BODIES_DIR + name + "_lod1.glb")
	K.check(fails, ps != null, "%s_lod1 loads" % name)
	if ps == null:
		return
	var lod := ps.instantiate()
	var meshes := lod.find_children("*", "MeshInstance3D", true, false)
	var skins := lod.find_children("*", "Skeleton3D", true, false)
	var tris := 0
	var surfaces := 0
	var skinned := false
	for m: Node in meshes:
		tris += _tris((m as MeshInstance3D).mesh)
		surfaces += (m as MeshInstance3D).mesh.get_surface_count()
		skinned = skinned or (m as MeshInstance3D).skin != null
	K.check(fails, meshes.size() == 1 and surfaces == 2 and tris <= 1500 and not skinned and skins.is_empty(), "%s_lod1: %d surfaces, %d tris, no skin" % [name, surfaces, tris])
	lod.free()


## Head and Neck: the rest axis closest to the model's +Z is the one A's LookAtModifier3D uses.
func _check_look_axis(name: String, sk: Skeleton3D) -> void:
	for b: String in ["Head", "Neck"]:
		var basis := sk.get_bone_global_rest(sk.find_bone(b)).basis.orthonormalized()
		var axes := [basis.x, -basis.x, basis.y, -basis.y, basis.z, -basis.z]
		var best := 0
		for i in axes.size():
			if (axes[i] as Vector3).dot(Vector3.BACK) > (axes[best] as Vector3).dot(Vector3.BACK):
				best = i
		K.check(fails, best == AP.CHAR_LOOK_AXIS, "%s: %s faces the model front along AP.CHAR_LOOK_AXIS (best axis %d)" % [name, b, best])


func _check_tracks(name: String, sk: Skeleton3D, lib: AnimationLibrary) -> void:
	var worst := 1.0
	var worst_clip := ""
	for n: StringName in lib.get_animation_list():
		var a := lib.get_animation(n)
		var ok := 0
		for t in a.get_track_count():
			var p := a.track_get_path(t)
			if String(p.get_concatenated_names()) == "%GeneralSkeleton" and sk.find_bone(p.get_concatenated_subnames()) >= 0:
				ok += 1
		var frac := float(ok) / maxf(a.get_track_count(), 1)
		if frac < worst:
			worst = frac
			worst_clip = String(n)
	K.check(fails, worst >= 0.95, "%s: >= 95%% of every clip's tracks resolve (worst %.2f %s)" % [name, worst, worst_clip])


## Poses and root motion through a real AnimationPlayer on the body.
func _check_motion(name: String, body: Node3D, sk: Skeleton3D, lib: AnimationLibrary) -> void:
	var ap := AnimationPlayer.new()
	body.add_child(ap)
	ap.root_node = NodePath("..")
	ap.add_animation_library("", lib)
	ap.root_motion_track = NodePath(AP.CHAR_ROOT_MOTION_TRACK)
	var h: float = (roster["bodies"][name] as Dictionary)["rest_height_m"]
	var hips := sk.find_bone("Hips")
	# walk for 1 s: hips height band, feet above the ground, no NaNs.
	ap.play("walk")
	var lo := INF
	var hi := -INF
	var foot_min := INF
	var nan := false
	for i in 11:
		_seek(ap, i * 0.1)
		var hp := _global(sk, hips).origin
		lo = minf(lo, hp.y)
		hi = maxf(hi, hp.y)
		for fb: String in FOOT_BONES:
			var fp := _global(sk, sk.find_bone(fb)).origin
			foot_min = minf(foot_min, fp.y)
			nan = nan or is_nan(fp.x + fp.y + fp.z)
		nan = nan or is_nan(hp.x + hp.y + hp.z)
	K.check(fails, not nan and lo / h >= WALK_HIPS.x and hi / h <= WALK_HIPS.y, "%s walk: hips %.3f-%.3f of height, no NaN" % [name, lo / h, hi / h])
	K.check(fails, foot_min >= -0.02, "%s walk: lowest foot %.3f m >= -0.02" % [name, foot_min])
	ap.play("sit")
	var sit_hi := -INF
	for t: float in [0.0, 1.0, 2.0]:
		_seek(ap, t)
		sit_hi = maxf(sit_hi, _global(sk, hips).origin.y)
	K.check(fails, sit_hi / h <= SIT_HIPS, "%s sit: hips at %.3f of height (<= %.2f)" % [name, sit_hi / h, SIT_HIPS])
	# Root travel over one loop equals speed_mps * T (scaled to this body's hips), and the hips do not drift.
	for clip: String in LOOP_TRAVEL:
		var a := lib.get_animation(StringName(clip))
		var speed: float = a.get_meta("speed_mps", 0.0) * sk.motion_scale / float(a.get_meta("speed_ref_hip_m", 1.0))
		ap.play(clip)
		_seek(ap, 0.0)
		var h0 := _global(sk, hips).origin
		var travel := Vector3.ZERO
		var steps := int(round(a.length * FPS))
		var track: Array[Vector2] = []
		for i in steps:
			ap.advance(a.length / steps)
			travel += ap.get_root_motion_position()
			var hp := _global(sk, hips).origin
			track.append(Vector2(hp.x, hp.z))
		var mean := Vector2.ZERO
		for p: Vector2 in track:
			mean += p / track.size()
		var sway := 0.0
		for p: Vector2 in track:
			sway = maxf(sway, p.distance_to(mean))
		var h1 := _global(sk, hips).origin
		var want := speed * a.length
		var drift := Vector2(h1.x - h0.x, h1.z - h0.z).length()
		K.check(fails, want > 0.1 and absf(travel.length() - want) <= 0.03 * want and travel.z > 0.0, "%s %s: root travel %.3f m vs speed_mps*T %.3f m (forward +Z)" % [name, clip, travel.length(), want])
		K.check(fails, drift < 0.05 and sway < 0.12, "%s %s: hips drift %.3f m over the loop, sway %.3f m (in place)" % [name, clip, drift, sway])
	# Loops start on the left-heel strike: the left foot is the lower one at t = 0 (+-1 frame).
	for clip: String in HEEL_STRIKE:
		ap.play(clip)
		var ok := false
		for t: float in [0.0, 1.0 / FPS]:
			_seek(ap, t)
			ok = ok or _global(sk, sk.find_bone("LeftFoot")).origin.y < _global(sk, sk.find_bone("RightFoot")).origin.y
		K.check(fails, ok, "%s %s: left foot lowest at t = 0" % [name, clip])
	ap.free()


func _seek(ap: AnimationPlayer, t: float) -> void:
	ap.seek(t, true)
	ap.advance(0.0)


## Bone pose in skeleton space from the local poses (independent of the skeleton's update timing).
func _global(sk: Skeleton3D, bone: int) -> Transform3D:
	var t := sk.get_bone_pose(bone)
	var p := sk.get_bone_parent(bone)
	while p >= 0:
		t = sk.get_bone_pose(p) * t
		p = sk.get_bone_parent(p)
	return t


# --- Roster, licences ----------------------------------------------------------------------------

func _check_roster() -> void:
	var man := _json(MANIFEST)
	var avatars: Dictionary = man.get("avatars", {})
	var heroes: Dictionary = roster.get("heroes", {})
	K.check(fails, heroes.get("m", "") == "Male_Adult_06" and heroes.get("f", "") == "Female_Adult_04", "roster heroes are Male_Adult_06 and Female_Adult_04")
	var pools: Dictionary = roster.get("job_pools", {})
	var casual: Dictionary = roster.get("casual_pools", {})
	var bad: Array[String] = []
	for job: String in Residents.OCCUPATIONS:
		for g: String in ["m", "f"]:
			var pick: Array[String] = []
			for n: String in pools.get(job, []):
				if avatars.has(n) and (avatars[n] as Dictionary).get("gender", "") == g:
					pick.append(n)
			if pick.is_empty():
				for n: String in casual.get(g, []):
					pick.append(n)
			var heroic := false
			for n: String in pick:
				heroic = heroic or n in heroes.values() or not (roster.get("bodies", {}) as Dictionary).has(n)
			if pick.is_empty() or heroic:
				bad.append("%s/%s" % [job, g])
	K.check(fails, not Residents.OCCUPATIONS.is_empty() and bad.is_empty(), "every job title has a pool of built non-hero bodies for both genders %s" % [bad])
	var genders: Dictionary = roster.get("name_gender", {})
	var odd: Array[String] = []
	for n: String in genders:
		if not n in Residents.FIRST_NAMES or not genders[n] in ["m", "f"]:
			odd.append(n)
	K.check(fails, genders.size() >= 40 and odd.is_empty(), "name_gender maps %d first names to m/f %s" % [genders.size(), odd])
	var built: Dictionary = roster.get("bodies", {})
	var unbuilt: Array[String] = []
	for n: String in avatars:
		if not built.has(n):
			unbuilt.append(n)
	K.check(fails, avatars.size() == 40 and unbuilt.is_empty(), "all %d manifest avatars are built %s" % [avatars.size(), unbuilt])
	for n: String in built:
		var b: Dictionary = built[n]
		var want: Dictionary = avatars.get(n, {})
		K.check(fails, b.get("gender", "") == want.get("gender", "?") and b.get("group", "") == want.get("group", "?"), "%s: roster gender and group match the manifest" % n)


func _check_licences() -> void:
	var dir := AP.CHARACTERS_DIR + "LICENSES/"
	for f: String in LICENCES:
		K.check(fails, FileAccess.get_file_as_string(dir + f).length() > 100, "licence %s is present" % f)
	var prov := _json(AP.CHARACTERS_DIR + "PROVENANCE.json")
	var man := _json(MANIFEST)
	var by_path := {}
	for e: Dictionary in man.get("files", []):
		by_path[e["path"]] = e["git_blob_sha1"]
	var rb: Dictionary = prov.get("rocketbox", {})
	var files: Array = rb.get("files", [])
	var mismatched := 0
	for e: Dictionary in files:
		if by_path.get(e["path"], "") != e["git_blob_sha1"]:
			mismatched += 1
	K.check(fails, rb.get("commit", "") == man.get("commit", "-") and files.size() >= 300 and mismatched == 0, "PROVENANCE rocketbox: %d files at the pinned commit, %d hash mismatches" % [files.size(), mismatched])
	var qua: Dictionary = _json(QUATERNIUS).get("packs", {})
	var qp: Dictionary = prov.get("quaternius", {})
	for pack: String in qua:
		var got: Dictionary = qp.get(pack, {})
		K.check(fails, got.get("sha256", "") == (qua[pack] as Dictionary)["sha256"], "PROVENANCE %s sha256 matches quaternius.json" % pack)


func _tris(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		n += idx.size() / 3 if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


func _json(path: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}
