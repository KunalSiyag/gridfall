class_name FpHud
extends CanvasLayer
## The lean on-foot HUD (slice B): named slots the HUD, chat and other slices fill, and B's widgets
## in them: indicator chips and the compass (top_bar), toasts and the alert banner (toasts), the
## rotating minimap and street label (minimap_slot), the interact prompt, first-person crosshair
## and district caption (center), and the pause menu, place card and full map (overlay). No AI or
## model branding: every string goes through SimDefs.debrand(). The minimap and map need the
## hud_widgets feature, which binds its tile model and waypoint with bind_widgets().

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const Chips := preload("res://scripts/fp/ui/hud_chips.gd")
const Toasts := preload("res://scripts/fp/ui/hud_toasts.gd")
const Compass := preload("res://scripts/fp/ui/hud_compass.gd")
const MinimapView := preload("res://scripts/fp/ui/minimap_view.gd")
const Prompt := preload("res://scripts/fp/ui/hud_prompt.gd")
const Caption := preload("res://scripts/fp/ui/hud_caption.gd")
const PauseMenu := preload("res://scripts/fp/ui/pause_menu.gd")
const PlaceCard := preload("res://scripts/fp/ui/place_card.gd")
const MapScreen := preload("res://scripts/fp/ui/map_screen.gd")

const SLOTS := ["top_bar", "minimap_slot", "chat_slot", "center", "toasts", "overlay"]
## [anchor_left, anchor_top, anchor_right, anchor_bottom, offset_left, offset_top, offset_right, offset_bottom]
## in the 1600x900 base viewport (canvas_items stretch).
const SLOT_RECTS := {
	"top_bar": [0.0, 0.0, 1.0, 0.0, 16, 12, -16, 64],
	"minimap_slot": [0.0, 1.0, 0.0, 1.0, 16, -252, 252, -16],
	"chat_slot": [0.0, 0.0, 0.0, 1.0, 0, 80, 460, -268],
	"center": [0.0, 0.0, 1.0, 1.0, 0, 0, 0, 0],
	"toasts": [0.5, 0.0, 0.5, 0.0, -320, 76, 320, 236],
	"overlay": [0.0, 0.0, 1.0, 1.0, 0, 0, 0, 0],
}
## Seconds a ping marker lives on the minimap and compass (it fades over the last third).
const PING_LIFE := 30.0
const MAX_PINGS := 8
## Short names for incident banners ("Fire reported near 214 Maple Street").
const EVENT_NOUNS := {
	"fire": "Fire", "blackout": "Power plant failure", "sewage_burst": "Sewage main burst",
	"gridlock": "Gridlock", "smog": "Toxic smog", "earthquake": "Earthquake", "flood": "Flooding",
	"tornado": "Tornado", "water_main": "Water main break", "power_line": "Downed power line",
	"car_crash": "Car crash",
}

var ctx: FpContext
var root: Control
var chips: Chips
var toasts: Toasts
var compass: Compass
var minimap: MinimapView
var prompt: Prompt
var caption: Caption
var pause_menu: PauseMenu
var card: PlaceCard
var map: MapScreen
## The hud_widgets feature once bound (minimap model and waypoint), else null.
var widgets: FpFeature
## Live pings: {"pos": Vector3, "reason": String, "age": float, "alpha": float}, oldest first.
var pings: Array[Dictionary] = []
var _slots: Dictionary = {}
var _hud_visible: bool = true
var _show_hud_setting: bool = true


## Builds the slots and every widget and connects to the bus.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	root = Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	for n: String in SLOTS:
		var r: Array = SLOT_RECTS[n]
		var c := Control.new()
		c.name = n
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.anchor_left = r[0]
		c.anchor_top = r[1]
		c.anchor_right = r[2]
		c.anchor_bottom = r[3]
		c.offset_left = r[4]
		c.offset_top = r[5]
		c.offset_right = r[6]
		c.offset_bottom = r[7]
		root.add_child(c)
		_slots[n] = c
	chips = Chips.new()
	slot("top_bar").add_child(chips)
	chips.setup(ctx)
	compass = Compass.new()
	slot("top_bar").add_child(compass)
	compass.setup(ctx, self)
	toasts = Toasts.new()
	slot("toasts").add_child(toasts)
	toasts.setup()
	minimap = MinimapView.new()
	slot("minimap_slot").add_child(minimap)
	minimap.setup(ctx, self)
	prompt = Prompt.new()
	slot("center").add_child(prompt)
	prompt.setup(ctx)
	caption = Caption.new()
	slot("center").add_child(caption)
	caption.setup(ctx)
	card = PlaceCard.new()
	slot("overlay").add_child(card)
	card.setup(ctx, self)
	map = MapScreen.new()
	slot("overlay").add_child(map)
	map.setup(ctx, self)
	pause_menu = PauseMenu.new()
	slot("overlay").add_child(pause_menu)
	pause_menu.setup(ctx, self)
	if ctx.bus != null:
		ctx.bus.toast.connect(show_toast)
		ctx.bus.ping.connect(_on_ping)
		ctx.bus.settings_changed.connect(_on_settings)
		ctx.bus.world_ready.connect(close_transient)
	_show_hud_setting = bool(ctx.settings.get("show_hud", true))
	if not _show_hud_setting:
		set_hud_visible(false)


## The slot Control by name (one of SLOTS); asserts on unknown names.
func slot(slot_name: String) -> Control:
	assert(_slots.has(slot_name), "FpHud: unknown slot " + slot_name)
	return _slots.get(slot_name, null)


## Hides or shows every slot except "overlay" (F1 and photo mode).
func set_hud_visible(v: bool) -> void:
	_hud_visible = v
	for n: String in SLOTS:
		if n != "overlay" and _slots.has(n):
			(_slots[n] as Control).visible = v


## True unless set_hud_visible(false) hid the slots.
func is_hud_visible() -> bool:
	return _hud_visible


## Queues a toast in the "toasts" slot. kind: info|alert|success|system|chat.
func show_toast(text: String, kind: String = "info") -> void:
	if toasts != null:
		toasts.show_toast(text, kind)


## Binds the hud_widgets feature: its model feeds the minimap and map, its waypoint the compass.
func bind_widgets(f: FpFeature) -> void:
	widgets = f
	var m: Variant = f.get("model") if f != null else null
	minimap.bind(m)
	map.bind(m)


## Drops the feature binding (feature teardown).
func unbind_widgets() -> void:
	widgets = null
	minimap.bind(null)
	map.bind(null)


## The waypoint (Vector3 at y = 0) or null.
func waypoint() -> Variant:
	if widgets != null and bool(widgets.get("has_waypoint")):
		return widgets.get("waypoint")
	return null


## The road route to the waypoint as world (x, z) points (empty without a waypoint).
func route() -> PackedVector2Array:
	if widgets != null and bool(widgets.get("has_waypoint")):
		return widgets.get("route")
	return PackedVector2Array()


## Sets the waypoint and announces it as a "player" ping (the map's left click).
func set_waypoint(p: Vector3) -> void:
	if widgets == null:
		return
	widgets.call("set_waypoint", Vector3(p.x, 0.0, p.z))
	if ctx.bus != null:
		ctx.bus.ping.emit(Vector3(p.x, 0.0, p.z), "player")


## Clears the waypoint.
func clear_waypoint() -> void:
	if widgets != null:
		widgets.call("clear_waypoint")


## Closes the place card and the full map and pops their modals (world_ready, load, New City).
func close_transient() -> void:
	if card != null:
		card.close()
	if map != null:
		map.close()
	pings.clear()
	if minimap != null:
		minimap.refresh_street()


func _process(delta: float) -> void:
	var k := 0
	while k < pings.size():
		var e: Dictionary = pings[k]
		var age := float(e["age"]) + delta
		if age >= PING_LIFE:
			pings.remove_at(k)
			continue
		e["age"] = age
		e["alpha"] = 1.0 - smoothstep(PING_LIFE * 0.66, PING_LIFE, age)
		k += 1
	_check_waypoint_reached()


func _check_waypoint_reached() -> void:
	var wp: Variant = waypoint()
	if wp == null or ctx.player == null:
		return
	var p: Vector3 = wp
	var me := ctx.player.position
	if Vector2(p.x - me.x, p.z - me.z).length() < 0.6:
		clear_waypoint()
		show_toast("Waypoint reached", "success")


func _on_ping(world_pos: Vector3, reason: String) -> void:
	if reason == "player":
		return
	pings.append({"pos": Vector3(world_pos.x, 0.0, world_pos.z), "reason": reason, "age": 0.0, "alpha": 1.0})
	while pings.size() > MAX_PINGS:
		pings.pop_front()
	var where := _place_near(world_pos)
	if reason.begins_with("event:"):
		var t := reason.substr(6)
		var noun := str(EVENT_NOUNS.get(t, (D.DISASTERS.get(t, {}) as Dictionary).get("label", "Incident")))
		toasts.show_banner("%s reported near %s" % [noun, where])
		return
	if reason.begins_with("resident:"):
		var who := "A resident"
		if ctx.residents != null:
			var r := ctx.residents.find(reason.substr(9))
			if not r.is_empty():
				who = str(r.get("name", who))
		show_toast("%s is near %s" % [who, where], "info")
	elif reason.begins_with("district:"):
		var mi := int(reason.substr(9))
		var dn := str(D.MAYORS[mi]["district"]) if mi >= 0 and mi < D.MAYORS.size() else "A district"
		show_toast("%s · marked on your map" % dn, "info")
	else:
		show_toast("Marked near %s" % where, "info")


## A directory place label for a world point ("214 Maple Street"), never raw coordinates.
func _place_near(p: Vector3) -> String:
	var x := roundi(p.x)
	var y := roundi(p.z)
	if ctx.directory == null or not D.in_bounds(x, y):
		return "the frontier"
	var t := ctx.directory.place_label(D.idx(x, y))
	return D.debrand(t) if not t.is_empty() else "the frontier"


func _on_settings(s: Dictionary) -> void:
	var v := bool(s.get("show_hud", true))
	if v != _show_hud_setting:
		_show_hud_setting = v
		set_hud_visible(v)
