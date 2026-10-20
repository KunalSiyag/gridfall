extends RefCounted
## Asset building for people.gd: the layered clips (a box held in both hands, a phone at the ear),
## the shared T0 AnimationTree, and HC's lod1 meshes as dither-fading T3 MultiMesh layers.

## Layered clips: the arm bones taken from another clip's pose at a fixed time.
const ARM_PARTS := [
	"Shoulder",
	"UpperArm",
	"LowerArm",
	"Hand",
	"ThumbMetacarpal",
	"ThumbProximal",
	"ThumbDistal",
	"IndexProximal",
	"IndexIntermediate",
	"IndexDistal",
	"MiddleProximal",
	"MiddleIntermediate",
	"MiddleDistal",
	"RingProximal",
	"RingIntermediate",
	"RingDistal",
	"LittleProximal",
	"LittleIntermediate",
	"LittleDistal"
]
const CARRY_AT := 0.0
const PHONE_AT := 0.5
const NEEDS: Array[StringName] = [
	&"idle", &"walk", &"talk", &"talk_2", &"phone", &"carry", &"idle_look", &"idle_wait", &"sit"
]
static var _crc_table := PackedInt64Array()
const T3_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque;
// HC's far LOD (lod1): albedo only. INSTANCE_CUSTOM.a is the opacity, dithered (fade in when
// spawned in view, fade out at the edge of VIS_PERSON).
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform vec4 albedo_col : source_color = vec4(1.0);
uniform float rough = 0.75;
varying float v_fade;

void vertex() {
	v_fade = INSTANCE_CUSTOM.a;
}

void fragment() {
	if (v_fade < 0.999) {
		float n = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (n >= v_fade) {
			discard;
		}
	}
	ALBEDO = texture(albedo_tex, UV).rgb * albedo_col.rgb;
	ROUGHNESS = rough;
}
"""


## A copy of HC's library with walk_carry, carry_idle and walk_phone added; the name of the first
## missing clip in NEEDS instead when it lacks one.
static func layered_library(hc: AnimationLibrary) -> Variant:
	var lib := AnimationLibrary.new()
	for n: StringName in hc.get_animation_list():
		lib.add_animation(n, hc.get_animation(n))
	for need: StringName in NEEDS:
		if not lib.has_animation(need):
			return String(need)
	var walk := lib.get_animation(&"walk")
	var carry := lib.get_animation(&"carry")
	var arms: Array[String] = []
	var right: Array[String] = []
	for part: String in ARM_PARTS:
		arms.append("Left" + part)
		arms.append("Right" + part)
		right.append("Right" + part)
	lib.add_animation(&"walk_carry", layer(walk, carry, arms, CARRY_AT, "walk_carry"))
	var idle := lib.get_animation(&"idle")
	lib.add_animation(&"carry_idle", layer(idle, carry, arms, CARRY_AT, "carry_idle"))
	var phone := lib.get_animation(&"phone")
	lib.add_animation(&"walk_phone", layer(walk, phone, right, PHONE_AT, "walk_phone"))
	return lib


## base with the rotations of `bones` replaced by over's pose at time `at` (constant keys).
static func layer(
	base: Animation, over: Animation, bones: Array[String], at: float, nm: String
) -> Animation:
	var a := base.duplicate() as Animation
	a.resource_name = nm
	for bone: String in bones:
		var path := NodePath("%GeneralSkeleton:" + bone)
		var oi := over.find_track(path, Animation.TYPE_ROTATION_3D)
		if oi < 0:
			continue
		var q := over.rotation_track_interpolate(oi, at)
		var ti := a.find_track(path, Animation.TYPE_ROTATION_3D)
		if ti >= 0:
			a.remove_track(ti)
		ti = a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(ti, path)
		a.rotation_track_insert_key(ti, 0.0, q)
	for k: StringName in base.get_meta_list():
		a.set_meta(k, base.get_meta(k))
	return a


## The T0 tree, shared by every body: state machine (every state reaches every other with a
## crossfade) -> TimeSeek (handovers from T1) -> TimeScale (playback rate) -> output.
static func build_tree(states: Array[StringName], xfade: float) -> AnimationNodeBlendTree:
	var sm := AnimationNodeStateMachine.new()
	for n: StringName in states:
		var an := AnimationNodeAnimation.new()
		an.animation = n
		sm.add_node(n, an)
	for x: StringName in states:
		for y: StringName in states:
			if x != y:
				var tr := AnimationNodeStateMachineTransition.new()
				tr.xfade_time = xfade
				sm.add_transition(x, y, tr)
	var bt := AnimationNodeBlendTree.new()
	bt.add_node(&"sm", sm)
	bt.add_node(&"seek", AnimationNodeTimeSeek.new())
	bt.add_node(&"rate", AnimationNodeTimeScale.new())
	bt.connect_node(&"seek", 0, &"sm")
	bt.connect_node(&"rate", 0, &"seek")
	bt.connect_node(&"output", 0, &"rate")
	return bt


static func t3_shader() -> Shader:
	var sh := Shader.new()
	sh.code = T3_SHADER
	return sh


## The first mesh of a lod1 scene as [ArrayMesh with the fade shader, its transform in the scene];
## [] when the scene has no mesh.
static func lod_mesh(ps: PackedScene, shader: Shader) -> Array:
	var inst := ps.instantiate() as Node3D
	var mis := inst.find_children("*", "MeshInstance3D", true, false)
	if mis.is_empty():
		inst.free()
		return []
	var mi := mis[0] as MeshInstance3D
	var xf := Transform3D.IDENTITY
	var n: Node = mi
	while n != null and n != inst:
		xf = (n as Node3D).transform * xf
		n = n.get_parent()
	var src := mi.mesh
	var out := ArrayMesh.new()
	for s in range(src.get_surface_count()):
		# Positions, normals, UVs and indices only (the imported arrays carry channels a plain
		# surface cannot take back).
		var arr := src.surface_get_arrays(s)
		var keep := []
		keep.resize(Mesh.ARRAY_MAX)
		for c: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_INDEX]:
			keep[c] = arr[c]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, keep)
		var sm := ShaderMaterial.new()
		sm.shader = shader
		var mat := src.surface_get_material(s)
		if mi.get_surface_override_material(s) != null:
			mat = mi.get_surface_override_material(s)
		if mat is BaseMaterial3D:
			sm.set_shader_parameter("albedo_tex", (mat as BaseMaterial3D).albedo_texture)
			sm.set_shader_parameter("albedo_col", (mat as BaseMaterial3D).albedo_color)
		out.surface_set_material(s, sm)
	inst.free()
	return [out, xf]


## An empty, hidden T3 layer for mesh (custom data carries the fade).
static func t3_layer(nm: String, mesh: Mesh) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 0
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-200, -10, -200), Vector3(400, 40, 400))
	mmi.visible = false
	return mmi


## Shows xfs (fade in the alpha of cols) on mmi, growing its buffer by doubling.
static func fill(mmi: MultiMeshInstance3D, xfs: Array[Transform3D], cols: Array[Color]) -> void:
	var mm := mmi.multimesh
	if xfs.is_empty():
		mmi.visible = false
		mm.visible_instance_count = 0
		return
	if mm.instance_count < xfs.size():
		mm.instance_count = maxi(xfs.size(), maxi(mm.instance_count * 2, 8))
	for k in range(xfs.size()):
		mm.set_instance_transform(k, xfs[k])
		mm.set_instance_custom_data(k, cols[k])
	mm.visible_instance_count = xfs.size()
	mmi.visible = true


## CRC-32 (IEEE, as zlib) of s's UTF-8 bytes.
static func crc32(s: String) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for i in range(256):
			var c := i
			for _k in range(8):
				c = (0xEDB88320 ^ (c >> 1)) if (c & 1) != 0 else (c >> 1)
			_crc_table[i] = c
	var crc := 0xFFFFFFFF
	for byte: int in s.to_utf8_buffer():
		crc = _crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF


## Bone pose in skeleton space from the local poses.
static func pose(sk: Skeleton3D, bone: int) -> Transform3D:
	var t := sk.get_bone_pose(bone)
	var p := sk.get_bone_parent(bone)
	while p >= 0:
		t = sk.get_bone_pose(p) * t
		p = sk.get_bone_parent(p)
	return t
