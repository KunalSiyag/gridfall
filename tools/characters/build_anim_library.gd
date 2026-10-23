extends SceneTree
## Builds the shared character animation libraries from the imported clip GLBs (HC deliverable 8).
## Run after the import: `godot --headless --path . -s tools/characters/build_anim_library.gd`.
##
## Reads models/characters/anim/clips.json (build_clips.py) and the imported rb_m.glb, rb_f.glb and
## ual.glb, then writes every clip to models/characters/anim/clips/<m|f|u>_<canonical>.res and the two
## AnimationLibrary resources lib_m.tres and lib_f.tres (with the hand-keyed clips of
## procedural_clips.gd), which reference those files (the UAL clips
## once, shared by both). Each Animation gets its loop mode and the metas `speed_mps` (Root speed in
## metres per second on the clip's own skeleton; UAL clips on the male hero's), `speed_ref_hip_m` (that
## skeleton's hip height, its motion_scale), `loop` and, for clips that turn, `root_turn_deg`.
## Prints ANIM_LIBRARY: PASS|FAIL.

const DIR := "res://models/characters/anim/"
const ROOT_TRACK := "%GeneralSkeleton:Root"
const SOURCES := {"m": DIR + "rb_m.glb", "f": DIR + "rb_f.glb", "u": DIR + "ual.glb"}
const PC := preload("res://tools/characters/procedural_clips.gd")

var fails: Array[String] = []


func _initialize() -> void:
	var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR + "clips.json"))
	if not report is Dictionary:
		_finish(["clips.json is missing or invalid"])
		return
	var clips: Dictionary = (report as Dictionary)["clips"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR + "clips"))
	var male_scale := _motion_scale(SOURCES["m"])
	var saved := {"m": {}, "f": {}, "u": {}}
	for src: String in ["m", "f", "u"]:
		var player := _player(SOURCES[src])
		if player == null:
			fails.append("no AnimationPlayer in " + SOURCES[src])
			continue
		var scale := male_scale if src == "u" else _motion_scale(SOURCES[src])
		for canon: String in clips:
			var entry: Dictionary = clips[canon]
			if not entry.has(src):
				continue
			var info: Dictionary = entry[src]
			if not player.has_animation(canon):
				fails.append("%s: clip %s missing from %s" % [src, canon, SOURCES[src]])
				continue
			var anim: Animation = player.get_animation(canon).duplicate(true)
			var looped: bool = info["loop"]
			anim.loop_mode = Animation.LOOP_LINEAR if looped else Animation.LOOP_NONE
			anim.resource_name = canon
			_set_metas(anim, scale, looped)
			var path := "%sclips/%s_%s.res" % [DIR, src, canon]
			var err := ResourceSaver.save(anim, path, ResourceSaver.FLAG_COMPRESS)
			if err != OK:
				fails.append("could not save %s (%d)" % [path, err])
				continue
			saved[src][canon] = path
			print("  %s_%-16s len=%6.3f loop=%s tracks=%d speed_mps=%.3f" % [src, canon, anim.length, looped, anim.get_track_count(), anim.get_meta("speed_mps")])
	_add_procedural(saved["u"], male_scale)
	for g: String in ["m", "f"]:
		var lib := AnimationLibrary.new()
		for src: String in [g, "u"]:
			for canon: String in saved[src]:
				lib.add_animation(StringName(canon), load(saved[src][canon]) as Animation)
		var lib_path := "%slib_%s.tres" % [DIR, g]
		var err := ResourceSaver.save(lib, lib_path)
		if err != OK:
			fails.append("could not save %s (%d)" % [lib_path, err])
		print("lib_%s: %d clips" % [g, lib.get_animation_list().size()])
	_finish(fails)


## The hand-keyed clips (procedural_clips.gd) as UAL clips: the kick, from punch_jab's stance.
func _add_procedural(saved_u: Dictionary, scale: float) -> void:
	if not saved_u.has("punch_jab"):
		fails.append("kick: punch_jab is missing")
		return
	var anim := PC.kick(load(saved_u["punch_jab"]) as Animation)
	anim.resource_name = "kick"
	_set_metas(anim, scale, false)
	var path := DIR + "clips/u_kick.res"
	var err := ResourceSaver.save(anim, path, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		fails.append("could not save %s (%d)" % [path, err])
		return
	saved_u["kick"] = path
	var n := anim.get_track_count()
	print("  u_kick             len=%6.3f tracks=%d (procedural)" % [anim.length, n])


## Root speed (m/s on a skeleton with `scale` motion scale), that scale, the loop flag and the turn
## angle as metas.
func _set_metas(anim: Animation, scale: float, looped: bool) -> void:
	var speed := 0.0
	var ri := anim.find_track(NodePath(ROOT_TRACK), Animation.TYPE_POSITION_3D)
	if ri >= 0 and anim.length > 0.0:
		var d := anim.position_track_interpolate(ri, anim.length) - anim.position_track_interpolate(ri, 0.0)
		speed = Vector2(d.x, d.z).length() * scale / anim.length
	anim.set_meta("speed_mps", snappedf(speed, 0.0001))
	anim.set_meta("speed_ref_hip_m", snappedf(scale, 0.0001))
	anim.set_meta("loop", looped)
	var qi := anim.find_track(NodePath(ROOT_TRACK), Animation.TYPE_ROTATION_3D)
	if qi >= 0:
		var q0 := anim.rotation_track_interpolate(qi, 0.0)
		var q1 := anim.rotation_track_interpolate(qi, anim.length)
		var turn := rad_to_deg((q0.inverse() * q1).get_euler().y)
		if absf(turn) > 1.0:
			anim.set_meta("root_turn_deg", snappedf(turn, 0.1))


func _player(path: String) -> AnimationPlayer:
	var node := _instance(path)
	if node == null:
		return null
	var found := node.find_children("*", "AnimationPlayer", true, false)
	return found[0] as AnimationPlayer if not found.is_empty() else null


func _motion_scale(path: String) -> float:
	var node := _instance(path)
	if node == null:
		return 1.0
	var found := node.find_children("*", "Skeleton3D", true, false)
	return (found[0] as Skeleton3D).motion_scale if not found.is_empty() else 1.0


## An instance of the scene at path, parented to the root so it is freed on quit; null if missing.
func _instance(path: String) -> Node:
	var ps := load(path) as PackedScene
	if ps == null:
		return null
	var node := ps.instantiate()
	root.add_child(node)
	return node


func _finish(errors: Array) -> void:
	if errors.is_empty():
		print("ANIM_LIBRARY: PASS")
	else:
		print("ANIM_LIBRARY: FAIL %s" % str(errors))
	quit(0 if errors.is_empty() else 1)
