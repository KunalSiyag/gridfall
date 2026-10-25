extends RefCounted
## Animated people from HC's roster (docs/fp/slices/E-traffic.md deliverable 9,
## TPS_PLAN §1.10-1.11).
## Rocketbox bodies on Godot's humanoid skeleton, picked by job, gender and crc32(resident id) for
## residents and by HC's ambient weights for the crowd, each under a CharacterRoot scaled to a
## jittered stature, animated by the gender's shared library plus three clips layered here at load
## (walk_carry and carry_idle hold a box, walk_phone a phone at the ear), with the playback rate
## matched to the walking speed so feet do not slide. LOD tiers by camera distance, 10 % hysteresis:
##   T0  <= 12 m, max 8   AnimationTree (state machine, 0.25 s crossfades), every frame, shadows
##   T1  12-30 m           AnimationPlayer advanced by hand, 30 Hz to 20 m (shadows) else 15 Hz
##   T2  30-60 m           the same at 10 Hz, no shadows
##   T3  to VIS_PERSON     HC's static mid-stride <Name>_lod1 in one MultiMesh per avatar
## T1 and T2 share a cap of SKIN_CAP bodies on screen, and everything stays inside DRAW_CAP
## character draws. Off-screen bodies keep their pose with their mixer inactive (and go back to the
## pool after OFF_KEEP). Bodies are pooled per avatar and instanced at most NEW_PER_FRAME per frame.
## Body and lod1 scenes load on background threads when first needed (a first load takes 25-150 ms;
## loading every avatar up front costs ~100 MB of textures); a walker whose body is still loading
## waits at T3, undrawn while its lod1 loads too. Asset building lives in people_kit.gd.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const KIT := preload("res://scripts/fp/traffic/people_kit.gd")
const T0_R := 12.0 * WS.M
const T0_CAP := 8
const T1_R := 30.0 * WS.M
const T1_NEAR := 20.0 * WS.M
const T2_R := 60.0 * WS.M
const HYST := 1.1
const SKIN_CAP := 40
const DRAW_CAP := 150
const HZ_NEAR := 30.0
const HZ_MID := 15.0
const HZ_FAR := 10.0
const NEW_PER_FRAME := 4
const OFF_KEEP := 4.0
const LOOK_CAP := 6
const XFADE := 0.25
## A person counts as walking above WALK_ON and as standing below WALK_OFF (u/s, as drawn).
const WALK_ON := 0.35 * WS.M
const WALK_OFF := 0.2 * WS.M
const RATE_MIN := 0.5
const RATE_MAX := 1.6
## People fade out over this last stretch before VIS_PERSON (T3).
const PERSON_FADE := 0.4
## Frustum test: a sphere around the body (metres above the feet, radius).
const CULL_UP := 0.9 * WS.M
const CULL_R := 1.3 * WS.M
const STATES := KIT.STATES
const LOCO: Array[StringName] = [&"walk", &"walk_carry", &"walk_phone"]
const STILL: Array[StringName] = [&"", &"carry_idle", &"phone"]
const BOX_COLOR := Color(0.62, 0.47, 0.3)


## One roster body (never a hero).
class Avatar:
	extends RefCounted
	var name: String = ""
	var gender: String = "m"
	var group: String = ""
	var rest_h: float = 1.75  # stature (m) the CharacterRoot scale divides by
	var hip_m: float = 0.9
	var path: String = ""
	var surfaces: int = 3
	var pool: Array = []  # free Body instances
	var made: int = 0
	var lod_mesh: Mesh = null  # lod1 with the fade shader, null until first needed (or missing)
	var lod_xf := Transform3D.IDENTITY
	var lod_tried: bool = false
	var mmi: MultiMeshInstance3D = null
	var t3: Array[Transform3D] = []
	var t3c: Array[Color] = []


## One instanced body: CharacterRoot > the body scene (Armature/GeneralSkeleton/Body, Anim, Tree).
class Body:
	extends RefCounted
	var av: int = -1
	var root: Node3D = null
	var scene: Node3D = null
	var skel: Skeleton3D = null
	var meshes: Array[GeometryInstance3D] = []
	var ap: AnimationPlayer = null
	var tree: AnimationTree = null
	var playback: AnimationNodeStateMachinePlayback = null
	var head: int = -1
	var walker: Object = null
	var mode: int = -1  # 0 tree, 1 player, -1 inactive (off screen or pooled)
	var clip: StringName = &""
	var acc: float = 0.0  # game seconds not yet advanced
	var since: float = 0.0  # real seconds since the last advance
	var shadow: int = -1
	var box: Node3D = null
	var look: LookAtModifier3D = null
	var off_t: float = 0.0
	var seen: int = -1


var ok: bool = false
var why: String = ""
## Load body and lod1 scenes on the calling thread (deterministic tests), not in the background.
var blocking: bool = false
var root: Node3D = null
var roster: Dictionary = {}
var avatars: Array = []
var _by_name: Dictionary = {}
var _libs: Dictionary = {}  # gender -> AnimationLibrary (HC's clips plus the layered ones)
var _speed: Dictionary = {}  # gender -> {clip: Root m/s on a skeleton with speed_ref_hip_m hips}
var _len: Dictionary = {}  # gender -> {clip: length s}
var _head_m: Dictionary = {"m": 1.59, "f": 1.533}
var _box_xf: Dictionary = {}  # gender -> box transform in UpperChest space
var _box_size: Dictionary = {}
var _box_mesh: Dictionary = {}
var _box_mat: StandardMaterial3D = null
var _tree_root: AnimationNodeBlendTree = null
var _t3_shader: Shader = null
var _look_target: Node3D = null
var _rng := RandomNumberGenerator.new()
var _city_seed: int = 0
var _height: Dictionary = {"target_m": 1.75, "female_factor": 0.95, "jitter": [0.97, 1.03]}
var _amb_groups: Array = []  # [[weight, [avatar indices]], ...]
var _scenes: Dictionary = {}  # path -> PackedScene (null: missing or failed)
var _pending: Dictionary = {}  # paths with a background load running
var _lod_frame: int = -1
# Frame state.
var _frame: int = 0
var _delta: float = 0.0
var _adt: float = 0.0
var _cam_pos := Vector3.ZERO
var _planes: Array[Plane] = []
var _cands: Array = []  # [distance, walker, on screen]
var _active: Array = []  # Body instances attached to walkers
var _seated: Array = []  # bodies lent by seat()
var _made_frame: int = 0
var _looks: int = 0
# Stats for anim_stats() (G2's bench) and the tests.
var t_counts: Array[int] = [0, 0, 0, 0]
var anim_us: float = 0.0
var people_us: float = 0.0
var char_draws: int = 0
var off_count: int = 0
var bodies_made: int = 0

# ------------------------------------------------------------------ loading


## Loads the roster and both libraries and builds the layered clips and the T0 tree. False (with
## `why`) when HC's characters are missing: E then draws the legacy static people.
func load_assets() -> bool:
	ok = false
	if not ResourceLoader.exists(AP.CHAR_ROSTER) and not FileAccess.file_exists(AP.CHAR_ROSTER):
		why = "roster.json missing"
		return false
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(AP.CHAR_ROSTER))
	if not v is Dictionary or not (v as Dictionary).has("bodies"):
		why = "roster.json missing or unreadable"
		return false
	roster = v
	var heroes: Array = (roster.get("heroes", {}) as Dictionary).values()
	var bodies: Dictionary = roster["bodies"]
	var names: Array = bodies.keys()
	names.sort()
	avatars.clear()
	_by_name.clear()
	for n: String in names:
		if n in heroes:
			continue
		var b: Dictionary = bodies[n]
		var a := Avatar.new()
		a.name = n
		a.gender = str(b.get("gender", "m"))
		a.group = str(b.get("group", ""))
		a.rest_h = float(b.get("rest_height_m", 1.75))
		a.hip_m = float(b.get("hip_m", 0.9))
		a.surfaces = int(b.get("surfaces", 3))
		a.path = str(b.get("path", AP.CHAR_BODIES_DIR + n + ".glb"))
		if not ResourceLoader.exists(a.path):
			continue
		_by_name[n] = avatars.size()
		avatars.append(a)
	if avatars.is_empty():
		why = "no roster body loads"
		return false
	if roster.has("height"):
		_height = roster["height"]
	for g: String in ["m", "f"]:
		var lp := AP.CHAR_LIB_M if g == "m" else AP.CHAR_LIB_F
		var hc := load(lp) as AnimationLibrary if ResourceLoader.exists(lp) else null
		if hc == null:
			why = "animation library %s missing" % g
			return false
		var made: Variant = KIT.layered_library(hc)
		if made is String:
			why = "lib_%s lacks %s" % [g, made]
			return false
		var lib: AnimationLibrary = made
		_libs[g] = lib
		var sp := {}
		var ln := {}
		for n: StringName in STATES:
			var a := lib.get_animation(n)
			sp[n] = (
				float(a.get_meta("speed_mps", 0.0))
				/ maxf(float(a.get_meta("speed_ref_hip_m", 1.0)), 0.01)
			)
			ln[n] = maxf(a.length, 0.01)
		_speed[g] = sp
		_len[g] = ln
	_tree_root = KIT.build_tree(STATES, XFADE)
	_build_ambient_groups()
	_t3_shader = KIT.t3_shader()
	_box_mat = StandardMaterial3D.new()
	_box_mat.albedo_color = BOX_COLOR
	_box_mat.roughness = 0.85
	ok = true
	why = ""
	return true


## Ambient mix: HC's weights over casual, business and the uniform groups (heroes never).
func _build_ambient_groups() -> void:
	_amb_groups.clear()
	var groups: Dictionary = roster.get("groups", {})
	var weights: Dictionary = roster.get(
		"ambient_weights", {"casual": 0.6, "business": 0.25, "uniform": 0.15}
	)
	var uniform: Array = roster.get(
		"uniform_groups", ["police", "medical", "fire", "trades", "service"]
	)
	for key: String in weights.keys():
		var members: Array[int] = []
		var gl: Array = uniform if key == "uniform" else [key]
		for g: String in gl:
			for n: String in groups.get(g, []):
				if _by_name.has(n):
					members.append(_by_name[n])
		if not members.is_empty():
			_amb_groups.append([float(weights[key]), members])


## Starts drawing under p_root (a new world): frees every body, keeps the loaded assets.
func reset(p_root: Node3D, city_seed: int) -> void:
	clear()
	root = p_root
	# Quitting with a background load in flight aborts it and logs parse errors for its materials.
	if not root.tree_exiting.is_connected(finish_loads):
		root.tree_exiting.connect(finish_loads)
	_city_seed = city_seed
	_rng.seed = city_seed * 6151 + 3
	_look_target = Node3D.new()
	_look_target.name = "PeopleLookTarget"
	root.add_child(_look_target)
	if ok:
		_probe("m")
		_probe("f")


## Frees every body and LOD layer.
func clear() -> void:
	for a: Avatar in avatars:
		for b: Body in a.pool:
			if is_instance_valid(b.root):
				b.root.queue_free()
		a.pool.clear()
		a.made = 0
		if a.mmi != null and is_instance_valid(a.mmi):
			a.mmi.queue_free()
		a.mmi = null
		a.t3.clear()
		a.t3c.clear()
	for b: Body in _active:
		if b.walker != null:
			b.walker.set("body", null)
		if is_instance_valid(b.root):
			b.root.queue_free()
	_active.clear()
	for b: Body in _seated:
		b.walker.set("body", null)
		b.root.queue_free()
	_seated.clear()
	if _look_target != null and is_instance_valid(_look_target):
		_look_target.queue_free()
	_look_target = null
	bodies_made = 0


## Measures a gender's skeleton once (head height, where the box sits in carry poses) on a first
## body, which then goes to its pool.
func _probe(g: String) -> void:
	var ai := -1
	for i in range(avatars.size()):
		if (avatars[i] as Avatar).gender == g:
			ai = i
			break
	if ai < 0 or root == null or not root.is_inside_tree():
		return
	var was := blocking
	blocking = true
	var b := _make(ai)
	blocking = was
	if b == null:
		return
	var sk := b.skel
	_head_m[g] = sk.get_bone_global_rest(sk.find_bone("Head")).origin.y
	b.ap.active = true
	b.ap.play(&"walk_carry")
	b.ap.seek(0.0, true)
	b.ap.advance(0.0)
	var lh := KIT.pose(sk, sk.find_bone("LeftHand")).origin
	var rh := KIT.pose(sk, sk.find_bone("RightHand")).origin
	var uc := KIT.pose(sk, sk.find_bone("UpperChest"))
	var across := lh - rh
	var w := clampf(across.length() - 0.06, 0.3, 0.5)
	var x := across.normalized()
	var fwd := x.cross(Vector3.UP).normalized()
	if fwd.z < 0.0:
		fwd = -fwd
	var up := fwd.cross(x).normalized()
	var c := (lh + rh) * 0.5 + fwd * 0.07 - up * 0.02
	_box_xf[g] = uc.affine_inverse() * Transform3D(Basis(x, up, fwd), c)
	_box_size[g] = Vector3(w, 0.26, 0.3)
	b.ap.stop()
	b.ap.active = false
	_release_body(b)


# ------------------------------------------------------------------ assignment


## CRC-32 (IEEE, as zlib) of s's UTF-8 bytes.
func crc32(s: String) -> int:
	return KIT.crc32(s)


## Gender of a resident: HC's name_gender for the first name, else crc32(id) & 1 (1 = f).
func resident_gender(rid: String, full_name: String) -> String:
	var first := full_name.split(" ")[0] if not full_name.is_empty() else ""
	var ng: Dictionary = roster.get("name_gender", {})
	if ng.has(first):
		return str(ng[first])
	return "f" if (crc32(rid) & 1) == 1 else "m"


## Avatar index for a resident: the job's pool for the gender, else the gender's casual pool,
## indexed by crc32(id). -1 when nothing fits.
func resident_avatar(rid: String, full_name: String, job: String) -> int:
	var g := resident_gender(rid, full_name)
	var pool: Array[int] = []
	for n: String in (roster.get("job_pools", {}) as Dictionary).get(job, []):
		if _by_name.has(n) and (avatars[_by_name[n]] as Avatar).gender == g:
			pool.append(_by_name[n])
	if pool.is_empty():
		for n: String in (roster.get("casual_pools", {}) as Dictionary).get(g, []):
			if _by_name.has(n):
				pool.append(_by_name[n])
	if pool.is_empty():
		return -1
	return pool[crc32(rid) % pool.size()]


## Stature (m) for a gender and a 0..1 jitter value.
func stature(g: String, u: float) -> float:
	var j: Array = _height.get("jitter", [0.97, 1.03])
	var base := (
		float(_height.get("target_m", 1.75))
		* (float(_height.get("female_factor", 0.95)) if g == "f" else 1.0)
	)
	return base * lerpf(float(j[0]), float(j[1]), clampf(u, 0.0, 1.0))


## Gives w its avatar and stature (once): residents by their id, ambient walkers from the city seed.
func dress(w: WK.Walker, residents: Variant) -> void:
	if w.av >= 0 or not ok:
		return
	if not w.resident_id.is_empty():
		var r: Dictionary = residents.find(w.resident_id) if residents != null else {}
		var ai := resident_avatar(
			w.resident_id, str(r.get("name", "")), str(r.get("job_title", ""))
		)
		if ai >= 0:
			w.av = ai
			var c := crc32(w.resident_id)
			w.h_m = stature((avatars[ai] as Avatar).gender, float((c >> 8) & 0xFFFF) / 65535.0)
			return
	_rng.seed = hash(Vector3i(_city_seed, w.id, 7919))
	var total := 0.0
	for gw: Array in _amb_groups:
		total += float(gw[0])
	var x := _rng.randf() * total
	var members: Array[int] = (_amb_groups[_amb_groups.size() - 1] as Array)[1]
	for gw: Array in _amb_groups:
		x -= float(gw[0])
		if x <= 0.0:
			members = gw[1]
			break
	w.av = members[_rng.randi() % members.size()]
	w.h_m = stature((avatars[w.av] as Avatar).gender, _rng.randf())


## Avatar name of walker w ("" before it is dressed).
func avatar_name(w: WK.Walker) -> String:
	return (avatars[w.av] as Avatar).name if w.av >= 0 and w.av < avatars.size() else ""


## CharacterRoot scale of w: WS.M * h_target / rest_height_m.
func scale_of(w: WK.Walker) -> float:
	var a: Avatar = avatars[w.av]
	return WS.M * w.h_m / a.rest_h


## Ground speed (u/s) clip covers at playback rate 1 on w's body.
func authored_speed(w: WK.Walker, clip: StringName) -> float:
	var a: Avatar = avatars[w.av]
	return float((_speed[a.gender] as Dictionary).get(clip, 0.0)) * a.hip_m * scale_of(w)


## World position of w's Head bone while a body draws it, else an estimate from its stature.
func head_of(w: WK.Walker, base: Vector3) -> Vector3:
	var b: Body = w.body
	if b != null and is_instance_valid(b.skel) and b.skel.is_inside_tree() and b.head >= 0:
		return (b.skel.global_transform * b.skel.get_bone_global_pose(b.head)).origin
	if w.av < 0:
		return base + Vector3(0, 1.59 * WS.M, 0)
	var a: Avatar = avatars[w.av]
	return base + Vector3(0, float(_head_m[a.gender]) * scale_of(w), 0)


# ------------------------------------------------------------------ per frame


## Starts a frame: delta is real seconds, adt game seconds (delta * sim.speed).
func begin(delta: float, adt: float, cam: Camera3D, cam_pos: Vector3, look_at: Vector3) -> void:
	_frame += 1
	_delta = delta
	_adt = adt
	_cam_pos = cam_pos
	_planes.clear()
	if cam != null and cam.is_inside_tree():
		for pl: Plane in cam.get_frustum():
			_planes.append(pl)
	_cands.clear()
	_made_frame = 0
	if _look_target != null:
		_look_target.position = look_at


## True when a body at feet position p could be on screen.
func on_screen(p: Vector3) -> bool:
	if _planes.is_empty():
		return true
	var c := p + Vector3(0, CULL_UP, 0)
	for pl: Plane in _planes:
		if pl.distance_to(c) > CULL_R:
			return false
	return true


## Queues walker w (eased already, d = camera distance) and advances its clip.
func add(w: WK.Walker, d: float, residents: Variant) -> void:
	dress(w, residents)
	if w.av < 0:
		return
	_animate(w)
	_cands.append([d, w, on_screen(w.pos + w.vis_off)])


## Picks w's clip from what it is doing (a reaction first) and advances its time (anim_t mirrors
## the mixer).
func _animate(w: WK.Walker) -> void:
	var g: String = (avatars[w.av] as Avatar).gender
	var moving := w.vis_v > WALK_ON or (w.vis_v > WALK_OFF and w.anim_clip in LOCO)
	var want: StringName
	if w.react != &"":
		want = w.react
	elif w.hold:
		want = &"talk"
	elif w.state == "chat":
		want = w.talk_clip
	elif moving:
		want = LOCO[w.extra]
	else:
		want = w.idle_clip if w.extra == 0 else STILL[w.extra]
	var lens: Dictionary = _len[g]
	if want != w.anim_clip:
		w.anim_clip = want
		# A mixer starts the new clip from its beginning; a body-less walker picks a phase, and a
		# reaction runs on its own clock.
		w.anim_t = 0.0 if w.body != null else _rng.randf() * float(lens[want])
		if w.react == want:
			w.anim_t = w.react_t
	var rate := w.react_rate if want == w.react else 1.0
	if want in LOCO or want == &"run":
		rate = clampf(w.vis_v / maxf(authored_speed(w, want), 1e-6), RATE_MIN, RATE_MAX)
	w.anim_rate = rate
	w.anim_t = KIT.clip_time(want, w.anim_t + _adt * rate, float(lens[want]))


## Assigns tiers, attaches, advances and releases bodies, and fills the T3 layers.
func finish() -> void:
	var t_start := Time.get_ticks_usec()
	_cands.sort_custom(_nearer)
	var tiers := _assign_tiers()
	_cap_draws(tiers)
	var us := _apply(tiers)
	# Bodies whose walker was not drawn this frame go back to their pools.
	for b: Body in _active.duplicate():
		if b.seen != _frame and b.walker != null:
			var w: WK.Walker = b.walker
			w.tier = -1
			_detach(w)
	for a: Avatar in avatars:
		_fill_t3(a)
	char_draws = 0
	for b: Body in _active:
		var w: WK.Walker = b.walker
		if w != null and w.tier >= 0 and w.tier <= 2:
			char_draws += _surfaces(w)
	for a: Avatar in avatars:
		if not a.t3.is_empty():
			char_draws += 2
	anim_us = float(us)
	people_us = float(Time.get_ticks_usec() - t_start)


static func _nearer(a: Array, b: Array) -> bool:
	return float(a[0]) < float(b[0])


## Tier per candidate (nearest first): 0-3 drawn, 4 off screen keeping its body, -1 nothing.
func _assign_tiers() -> Array[int]:
	var tiers: Array[int] = []
	tiers.resize(_cands.size())
	var t0 := 0
	var skinned := 0
	for k in range(_cands.size()):
		var want := _tier_for(_cands[k][1], float(_cands[k][0]), bool(_cands[k][2]), t0 < T0_CAP)
		if (want == 1 or want == 2) and skinned >= SKIN_CAP:
			want = 3
		if want == 0:
			t0 += 1
		elif want == 1 or want == 2:
			skinned += 1
		tiers[k] = want
	return tiers


## w's tier by camera distance d, with HYST on the side of the tier it is in.
func _tier_for(w: WK.Walker, d: float, seen: bool, t0_free: bool) -> int:
	var prev := w.tier
	if not seen:
		return 4 if (w.body != null and d < T2_R * HYST) else -1
	if w.fade < 1.0:
		return 3
	if t0_free and d < T0_R * (HYST if prev == 0 else 1.0):
		return 0
	if d < T1_R * (HYST if prev >= 0 and prev <= 1 else 1.0):
		return 1
	if d < T2_R * (HYST if prev >= 0 and prev <= 2 else 1.0):
		return 2
	return 3


## Character draws: skinned surfaces (and boxes) on screen plus two per avatar in T3. Over
## DRAW_CAP the farthest T1/T2 bodies drop to T3.
func _cap_draws(tiers: Array[int]) -> void:
	var draws := 0
	var t3_avs := {}
	for k in range(_cands.size()):
		var w: WK.Walker = _cands[k][1]
		if tiers[k] >= 0 and tiers[k] <= 2:
			draws += _surfaces(w)
		elif tiers[k] == 3:
			t3_avs[w.av] = true
	draws += 2 * t3_avs.size()
	var k := _cands.size() - 1
	while draws > DRAW_CAP and k >= 0:
		if tiers[k] == 1 or tiers[k] == 2:
			var w: WK.Walker = _cands[k][1]
			draws -= _surfaces(w)
			tiers[k] = 3
			if not t3_avs.has(w.av):
				t3_avs[w.av] = true
				draws += 2
		k -= 1


## Applies the tiers; returns the microseconds spent advancing mixers.
func _apply(tiers: Array[int]) -> int:
	for a: Avatar in avatars:
		a.t3.clear()
		a.t3c.clear()
	t_counts = [0, 0, 0, 0]
	off_count = 0
	_looks = 0
	var us := 0
	for k in range(_cands.size()):
		us += _apply_one(_cands[k][1], tiers[k], float(_cands[k][0]))
	return us


func _apply_one(w: WK.Walker, tier: int, d: float) -> int:
	if tier >= 0 and tier <= 2 and w.body == null and not _attach(w, tier):
		tier = 3
	if tier == 3 or tier == -1:
		_detach(w)
	w.tier = tier
	if tier == 3:
		_t3(w, d)
		t_counts[3] += 1
		return 0
	if tier < 0:
		return 0
	var b: Body = w.body
	b.seen = _frame
	if tier == 4:
		_hold_off(b, w)
		return 0
	b.off_t = 0.0
	t_counts[tier] += 1
	return _drive(b, w, tier, d)


## An off-screen body keeps its pose with its mixer inactive; back to the pool after OFF_KEEP.
func _hold_off(b: Body, w: WK.Walker) -> void:
	off_count += 1
	b.off_t += _delta
	if b.mode != -1:
		_set_mode(b, w, -1)
	if b.off_t > OFF_KEEP:
		_detach(w)
		w.tier = -1


func _surfaces(w: WK.Walker) -> int:
	return (avatars[w.av] as Avatar).surfaces + (1 if w.extra == 1 else 0)


## Places, shades and animates w's body for tier; returns the microseconds spent advancing.
func _drive(b: Body, w: WK.Walker, tier: int, d: float) -> int:
	var s := scale_of(w)
	b.root.transform = WK.body_xf(w, s, _feet(w))
	_set_shadow(b, tier == 0 or (tier == 1 and d < T1_NEAR))
	if b.box != null:
		b.box.visible = w.extra == 1 and w.anim_clip in [&"walk_carry", &"carry_idle"]
	_look(b, w, tier)
	var want_mode := 0 if tier == 0 else 1
	var t0 := Time.get_ticks_usec()
	if b.mode != want_mode:
		_set_mode(b, w, want_mode)
		return Time.get_ticks_usec() - t0
	b.acc += _adt
	b.since += _delta
	if b.acc <= 0.0 and b.clip == w.anim_clip:
		return 0
	if want_mode == 0:
		if b.clip != w.anim_clip:
			b.playback.travel(w.anim_clip)
			b.clip = w.anim_clip
		b.tree.set(&"parameters/rate/scale", w.anim_rate)
		b.tree.advance(b.acc)
		b.acc = 0.0
		b.since = 0.0
		return Time.get_ticks_usec() - t0
	var hz := HZ_NEAR if (tier == 1 and d < T1_NEAR) else (HZ_MID if tier == 1 else HZ_FAR)
	if b.since < 1.0 / hz and b.clip == w.anim_clip:
		return 0
	if b.clip != w.anim_clip:
		b.ap.play(w.anim_clip, KIT.REACT_XFADE if w.anim_clip in KIT.BLOWS else XFADE)
		b.clip = w.anim_clip
	# speed_scale applies to the whole interval since the last update (game seconds in acc).
	b.ap.speed_scale = w.anim_rate
	b.ap.advance(b.acc)
	b.acc = 0.0
	b.since = fmod(b.since, 1.0 / hz)
	return Time.get_ticks_usec() - t0


func _set_shadow(b: Body, on: bool) -> void:
	var sh := 1 if on else 0
	if sh == b.shadow:
		return
	b.shadow = sh
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if on:
		mode = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for gi: GeometryInstance3D in b.meshes:
		gi.cast_shadow = mode
	if b.box != null:
		(b.box.get_child(0) as GeometryInstance3D).cast_shadow = mode


## Switches b to the tree (0), the player (1) or neither (-1), carrying w's clip and time over.
func _set_mode(b: Body, w: WK.Walker, mode: int) -> void:
	# The clip time to carry over: the outgoing mixer's when it plays w's clip.
	if b.mode == 0 and b.playback != null and b.playback.get_current_node() == w.anim_clip:
		w.anim_t = b.playback.get_current_play_position()
	elif b.mode == 1 and b.ap.current_animation == String(w.anim_clip):
		w.anim_t = b.ap.current_animation_position
	b.mode = mode
	b.acc = 0.0
	b.since = 0.0
	b.clip = w.anim_clip
	if mode == 0:
		b.ap.active = false
		b.tree.active = true
		b.tree.set(&"parameters/rate/scale", w.anim_rate)
		b.playback.start(w.anim_clip, true)
		b.tree.advance(0.0)
		b.tree.set(&"parameters/seek/seek_request", w.anim_t)
		b.tree.advance(0.0)
	elif mode == 1:
		b.tree.active = false
		b.ap.active = true
		b.ap.stop()
		b.ap.play(w.anim_clip)
		b.ap.speed_scale = w.anim_rate
		b.ap.seek(w.anim_t, true)
		b.ap.advance(0.0)
		b.since = _rng.randf() / HZ_NEAR
	else:
		b.tree.active = false
		b.ap.active = false


## Conversation partners at T0 turn their head toward the player (at most LOOK_CAP of them).
func _look(b: Body, w: WK.Walker, tier: int) -> void:
	var want := (
		w.hold and w.face_player and tier == 0 and _looks < LOOK_CAP and _look_target != null
	)
	if want:
		_looks += 1
		if b.look == null:
			var lm := LookAtModifier3D.new()
			lm.name = "HeadLook"
			lm.bone_name = "Head"
			lm.forward_axis = AP.CHAR_LOOK_AXIS
			lm.primary_rotation_axis = Vector3.AXIS_Y
			lm.use_angle_limitation = true
			lm.primary_limit_angle = deg_to_rad(140.0)
			lm.secondary_limit_angle = deg_to_rad(70.0)
			lm.duration = 0.4
			b.skel.add_child(lm)
			lm.target_node = lm.get_path_to(_look_target)
			b.look = lm
		b.look.active = true
	elif b.look != null and b.look.active:
		b.look.active = false


func _feet(w: WK.Walker) -> Vector3:
	var p := w.pos + w.vis_off
	if w.acc_dt > 0.0 and w.v > 0.0 and w.state == "walk" and not w.hold:
		p += w.vel * w.acc_dt
	return p


## Gives dressed walker w a body outside the tiers (a seated driver, posed by occupants.gd); false
## while none is free. release(w) hands it back.
func seat(w: WK.Walker) -> bool:
	var b := _take(w.av)
	if b == null:
		return false
	b.walker = w
	w.body = b
	b.root.visible = true
	_seated.append(b)
	return true


## A pooled body of avatar ai, or a new one within this frame's budget once its scene has loaded.
func _take(ai: int) -> Body:
	var a: Avatar = avatars[ai]
	if not a.pool.is_empty():
		return a.pool.pop_back()
	if _made_frame < NEW_PER_FRAME and _scene(a.path) != null:
		_made_frame += 1
		return _make(ai)
	return null


## Gives w a body (pooled, or new within this frame's budget). False when none is available.
func _attach(w: WK.Walker, tier: int) -> bool:
	var a: Avatar = avatars[w.av]
	var b := _take(w.av)
	if b == null:
		return false
	b.walker = w
	w.body = b
	b.off_t = 0.0
	b.seen = _frame
	b.shadow = -1
	b.mode = -1
	b.root.visible = true
	if w.extra == 1:
		_ensure_box(b, a.gender)
	if b.box != null:
		b.box.visible = false
	_active.append(b)
	_set_mode(b, w, 0 if tier == 0 else 1)
	return true


## Returns w's body (if any) to its pool.
func _detach(w: WK.Walker) -> void:
	var b: Body = w.body
	if b == null:
		return
	if b.mode == 0 and b.playback != null and b.playback.get_current_node() == w.anim_clip:
		w.anim_t = b.playback.get_current_play_position()
	elif b.mode == 1 and b.ap.current_animation == String(w.anim_clip):
		w.anim_t = b.ap.current_animation_position
	w.body = null
	_active.erase(b)
	_seated.erase(b)
	_release_body(b)


func _release_body(b: Body) -> void:
	b.walker = null
	b.mode = -1
	if is_instance_valid(b.tree):
		b.tree.active = false
	if is_instance_valid(b.ap):
		b.ap.active = false
	if b.look != null:
		b.look.active = false
	if is_instance_valid(b.root):
		b.root.visible = false
	(avatars[b.av] as Avatar).pool.append(b)


## A walker leaves for good (removed): its body goes back to the pool.
func release(w: WK.Walker) -> void:
	_detach(w)
	w.tier = -1


## The PackedScene at path: loaded at once when blocking, else from a background load (null while
## that runs, and for good when it fails or the file is missing).
func _scene(path: String) -> PackedScene:
	if _scenes.has(path):
		return _scenes[path]
	if not _pending.has(path):
		if not ResourceLoader.exists(path):
			_scenes[path] = null
			return null
		if blocking:
			_scenes[path] = AP.load_scene(path)
			return _scenes[path]
		if ResourceLoader.load_threaded_request(path, "PackedScene", true) != OK:
			_scenes[path] = null
			return null
		_pending[path] = true
	if (
		not blocking
		and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS
	):
		return null
	# Finished, failed, or blocking (load_threaded_get then waits for the load).
	_pending.erase(path)
	var ps := ResourceLoader.load_threaded_get(path) as PackedScene
	_scenes[path] = ps
	return ps


## Waits for every background scene load still running and keeps the results.
func finish_loads() -> void:
	for path: String in _pending.keys():
		_scenes[path] = ResourceLoader.load_threaded_get(path) as PackedScene
	_pending.clear()


func _make(ai: int) -> Body:
	var a: Avatar = avatars[ai]
	var ps := _scene(a.path)
	if ps == null:
		return null
	var b := Body.new()
	b.av = ai
	b.root = Node3D.new()
	b.root.name = "CharacterRoot_%s_%d" % [a.name, a.made]
	b.scene = ps.instantiate() as Node3D
	b.root.add_child(b.scene)
	root.add_child(b.root)
	b.skel = b.scene.get_node_or_null("%GeneralSkeleton") as Skeleton3D
	if b.skel == null:
		b.root.queue_free()
		return null
	b.head = b.skel.find_bone("Head")
	for n: Node in b.scene.find_children("*", "GeometryInstance3D", true, false):
		b.meshes.append(n as GeometryInstance3D)
	var lib: AnimationLibrary = _libs[a.gender]
	b.ap = AnimationPlayer.new()
	b.ap.name = "Anim"
	b.scene.add_child(b.ap)
	b.ap.add_animation_library("", lib)
	b.ap.root_motion_track = NodePath(AP.CHAR_ROOT_MOTION_TRACK)
	b.ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	b.ap.active = false
	b.tree = AnimationTree.new()
	b.tree.name = "Tree"
	b.scene.add_child(b.tree)
	b.tree.add_animation_library("", lib)
	b.tree.root_motion_track = NodePath(AP.CHAR_ROOT_MOTION_TRACK)
	b.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	b.tree.tree_root = _tree_root
	b.tree.active = false
	b.playback = b.tree.get(&"parameters/sm/playback")
	a.made += 1
	bodies_made += 1
	return b


## A cardboard box held in front of the chest (carry poses), parented to UpperChest.
func _ensure_box(b: Body, g: String) -> void:
	if b.box != null or not _box_xf.has(g):
		return
	if not _box_mesh.has(g):
		var bm := BoxMesh.new()
		bm.size = _box_size[g]
		bm.material = _box_mat
		_box_mesh[g] = bm
	var att := BoneAttachment3D.new()
	att.name = "Box"
	att.bone_name = "UpperChest"
	b.skel.add_child(att)
	var mi := MeshInstance3D.new()
	mi.mesh = _box_mesh[g]
	mi.transform = _box_xf[g]
	att.add_child(mi)
	b.box = att


# ------------------------------------------------------------------ T3


func _t3(w: WK.Walker, d: float) -> void:
	var a: Avatar = avatars[w.av]
	if not a.lod_tried:
		_load_lod(a)
	if a.lod_mesh == null:
		return
	var op := minf(w.fade, clampf((WS.VIS_PERSON - d) / PERSON_FADE, 0.0, 1.0))
	if op <= 0.0:
		return
	var s := scale_of(w)
	a.t3.append(WK.body_xf(w, s, _feet(w)) * a.lod_xf)
	a.t3c.append(Color(0, 0, 0, op))


## HC's <Name>_lod1.glb as one mesh whose surfaces dither-fade (T3), once its scene has loaded; at
## most one built per frame (copying the surfaces takes a few ms).
func _load_lod(a: Avatar) -> void:
	if _lod_frame == _frame and not blocking:
		return
	var path := a.path.get_basename() + "_lod1.glb"
	var ps := _scene(path)
	if _pending.has(path):
		return
	_lod_frame = _frame
	a.lod_tried = true
	if ps == null:
		return
	var built := KIT.lod_mesh(ps, _t3_shader)
	if built.is_empty():
		return
	a.lod_mesh = built[0]
	a.lod_xf = built[1]
	a.mmi = KIT.t3_layer("T3_%s" % a.name, a.lod_mesh)
	root.add_child(a.mmi)


func _fill_t3(a: Avatar) -> void:
	if a.mmi == null:
		return
	KIT.fill(a.mmi, a.t3, a.t3c)


# ------------------------------------------------------------------ stats


## anim_stats() for G2's bench: tier counts on screen, microseconds advancing mixers this frame,
## character draws (skinned surfaces and boxes on screen plus two per T3 avatar layer).
func stats() -> Dictionary:
	return {
		"t0": t_counts[0],
		"t1": t_counts[1],
		"t2": t_counts[2],
		"t3": t_counts[3],
		"anim_us": anim_us,
		"char_draws": char_draws,
		"off": off_count,
		"bodies": bodies_made,
		"people_us": people_us
	}
