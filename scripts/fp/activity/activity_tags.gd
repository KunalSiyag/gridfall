extends Control
## Floating tags over the AI beacons (feature "activity"): for each beacon in front of the camera
## and within RANGE, who decided and what, with the distance, pinned above the ground at the beacon
## (lower when near, so a close beacon's tag stays in view). Nearest first; a tag that would leave
## the screen, cover a HUD area the caller keeps clear or overlap a placed tag is left out instead
## of being pushed to the edge. Hidden with the HUD, under modals and in photo mode.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

## Tiles (world units) within which a beacon gets a tag.
const RANGE := 30.0
## Height of a tag over its beacon's foot: LIFT_PER of the distance, between LIFT_MIN and LIFT.
const LIFT := 14.0 * WS.M
const LIFT_MIN := 2.5 * WS.M
const LIFT_PER := 0.3
const MAX_TAGS := 4
const SAFE := 24.0
const GAP := 4.0

## Pool of {"panel": PanelContainer, "who": Label, "what": Label}.
var _pool: Array[Dictionary] = []
var _shown: Array[String] = []


func setup() -> void:
	name = "ActivityTags"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## entries: [{"key", "pos": Vector3 (beacon foot), "who", "what", "color": Color}], me: the
## player's position, avoid: rects (in this control's coordinates) no tag may cover. Places up to
## MAX_TAGS tags for cam; [] or a null cam hides them.
func show_tags(entries: Array, cam: Camera3D, me: Vector3, avoid: Array[Rect2] = []) -> void:
	_shown.clear()
	var view := size if size.x > 0.0 else get_viewport_rect().size
	var screen := Rect2(Vector2(SAFE, SAFE), view - Vector2(SAFE, SAFE) * 2.0)
	var near: Array = []
	if cam != null and cam.is_inside_tree():
		for e: Dictionary in entries:
			var p: Vector3 = e["pos"]
			var d := Vector2(p.x - me.x, p.z - me.z).length()
			var top := p + Vector3.UP * clampf(d * LIFT_PER, LIFT_MIN, LIFT)
			if d <= RANGE and not cam.is_position_behind(top):
				near.append([d, e, cam.unproject_position(top)])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var placed: Array[Rect2] = avoid.duplicate()
	var k := 0
	for n: Array in near:
		if k >= MAX_TAGS:
			break
		var e: Dictionary = n[1]
		var t := _tag(k)
		var color: Color = e["color"]
		var who: Label = t["who"]
		who.text = str(e["who"])
		# Re-applying an equal override still re-shapes the label, and this runs every frame.
		var tint := color.lerp(S.WHITE, 0.4)
		if who.get_theme_color("font_color") != tint:
			who.add_theme_color_override("font_color", tint)
		(t["what"] as Label).text = "%s · %s" % [str(e["what"]), S.distance(float(n[0]))]
		var p: PanelContainer = t["panel"]
		var sz := p.get_combined_minimum_size()
		p.size = sz
		var at: Vector2 = n[2] - Vector2(sz.x * 0.5, sz.y)
		var r := Rect2(at, sz).grow(GAP)
		var hit := placed.any(func(q: Rect2) -> bool: return q.intersects(r))
		if hit or not screen.encloses(Rect2(at, sz)):
			continue
		placed.append(r)
		p.position = at.round()
		p.visible = true
		var box: StyleBoxFlat = t["box"]
		if box.border_color != color:
			box.border_color = color
		_shown.append(str(e["key"]))
		k += 1
	for j in range(k, _pool.size()):
		(_pool[j]["panel"] as Control).visible = false


## Keys of the beacons tagged on screen now (tests).
func shown() -> Array[String]:
	return _shown


func _tag(k: int) -> Dictionary:
	while _pool.size() <= k:
		var p := PanelContainer.new()
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := S.stripe(S.box(Color(0.03, 0.04, 0.07, 0.62), S.RADIUS, 8, 4), S.ACCENT, 2)
		p.add_theme_stylebox_override("panel", sb)
		var v := VBoxContainer.new()
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_theme_constant_override("separation", 0)
		p.add_child(v)
		var who := S.caps_label("", 11, S.WHITE, 2)
		v.add_child(who)
		var what := S.label("", 13, S.TEXT, S.bold(), 2)
		v.add_child(what)
		p.visible = false
		add_child(p)
		_pool.append({"panel": p, "box": sb, "who": who, "what": what})
	return _pool[k]
