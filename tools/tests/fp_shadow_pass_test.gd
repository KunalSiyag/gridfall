extends SceneTree
## Web-tier shadow budget: junction kit parts and signal/sign GLB children leave the shadow pass
## (a lens or sign face casts nothing a walker reads, and each caster is a shadow-pass draw).
## Desktop (vis_mult 1.0) keeps every shadow. Sites need nothing: their small parts already ask
## for shadow=false and the merge buckets the rest (probe: identical caster sets across tiers).

const JN := preload("res://scripts/fp/traffic/junctions.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const K := preload("res://tools/tests/fp_kit.gd")


## How many of the instance's geometry children still cast.
func _casters(inst: Node3D) -> int:
	var on := 0
	for n in inst.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			on += 1
	return on


func _light() -> Node3D:
	return (AP.load_scene(AP.TRAFFIC_LIGHT) as PackedScene).instantiate() as Node3D


func _initialize() -> void:
	var fails: Array[String] = []
	var jn: JN = JN.new()
	# Junction kit parts: shadows and range follow the tier.
	jn.vis_mult = 0.55
	var web_mi := jn._mi(BoxMesh.new(), null, true)
	K.check(
		fails,
		web_mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"web kit parts leave the shadow pass"
	)
	K.check(
		fails,
		is_equal_approx(web_mi.visibility_range_end, WS.VIS_PROP * 0.55),
		"kit part range scales with the preset"
	)
	jn.vis_mult = 1.0
	var desk_mi := jn._mi(BoxMesh.new(), null, true)
	K.check(
		fails,
		desk_mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"desktop kit parts keep their shadows"
	)
	K.check(
		fails,
		is_equal_approx(desk_mi.visibility_range_end, WS.VIS_PROP),
		"desktop kit range unchanged"
	)
	# The signal GLB's children: shadow-stripped on web, untouched on desktop.
	var web_light := _light()
	root.add_child(web_light)
	jn.vis_mult = 0.55
	jn._range_asset(web_light)
	K.check(fails, _casters(web_light) == 0, "signal GLB children cast nothing on the web tier")
	web_light.free()
	var desk_light := _light()
	root.add_child(desk_light)
	jn.vis_mult = 1.0
	jn._range_asset(desk_light)
	K.check(fails, _casters(desk_light) > 0, "desktop keeps the GLB shadows")
	desk_light.free()
	K.finish(self, "FP_SHADOW_PASS_TEST", fails)
