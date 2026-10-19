extends FpFeature
## Lean HUD widgets (slice B): owns the minimap tile model and the waypoint, binds them to FpHud
## (minimap, full map, compass), keeps the model painted (per tile on tiles_changed, per district
## on territory_changed, in full on world_ready), closes B's transient UI after a load and saves
## the waypoint as {"waypoint": [x, z]}.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const MinimapModel := preload("res://scripts/fp/ui/minimap_model.gd")
const GpsRoute := preload("res://scripts/fp/ui/gps_route.gd")

var model: MinimapModel
## The waypoint (world, y = 0) while has_waypoint.
var waypoint: Vector3 = Vector3.ZERO
var has_waypoint: bool = false
## Road route from the player to the waypoint, world (x, z) corner points; empty without one.
var route: PackedVector2Array = PackedVector2Array()
var _painted_frame: int = -1
var _dirty: bool = false
var _route_dirty: bool = false


func feature_id() -> String:
	return "hud_widgets"


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	model = MinimapModel.new()
	model.setup(ctx.sim)
	if ctx.sim != null:
		ctx.sim.tiles_changed.connect(_on_tiles_changed)
		ctx.sim.territory_changed.connect(_on_territory_changed)
	if ctx.bus != null:
		ctx.bus.world_ready.connect(_on_world_ready)
		ctx.bus.player_tile_changed.connect(_on_player_tile)
	_full_repaint()
	if ctx.hud != null:
		ctx.hud.bind_widgets(self)


func on_world_rebuilt() -> void:
	_full_repaint()


func to_dict() -> Dictionary:
	if not has_waypoint:
		return {}
	return {"waypoint": [waypoint.x, waypoint.z]}


func from_dict(d: Dictionary) -> void:
	has_waypoint = false
	var w: Variant = d.get("waypoint", null)
	if typeof(w) == TYPE_ARRAY and (w as Array).size() >= 2:
		set_waypoint(Vector3(float(w[0]), 0.0, float(w[1])))
	if ctx != null and ctx.hud != null:
		ctx.hud.close_transient()


func teardown() -> void:
	if ctx == null:
		return
	if ctx.sim != null:
		if ctx.sim.tiles_changed.is_connected(_on_tiles_changed):
			ctx.sim.tiles_changed.disconnect(_on_tiles_changed)
		if ctx.sim.territory_changed.is_connected(_on_territory_changed):
			ctx.sim.territory_changed.disconnect(_on_territory_changed)
	if ctx.bus != null and ctx.bus.world_ready.is_connected(_on_world_ready):
		ctx.bus.world_ready.disconnect(_on_world_ready)
	if ctx.bus != null and ctx.bus.player_tile_changed.is_connected(_on_player_tile):
		ctx.bus.player_tile_changed.disconnect(_on_player_tile)
	if ctx.hud != null and is_instance_valid(ctx.hud):
		ctx.hud.unbind_widgets()


## Sets the waypoint (world point; y is ignored) and routes to it.
func set_waypoint(p: Vector3) -> void:
	waypoint = Vector3(p.x, 0.0, p.z)
	has_waypoint = true
	reroute()


func clear_waypoint() -> void:
	has_waypoint = false
	route = PackedVector2Array()


## Recomputes the road route from the player to the waypoint (on set, on every tile the player
## enters, and after roads change).
func reroute() -> void:
	_route_dirty = false
	route = PackedVector2Array()
	if has_waypoint and ctx != null and ctx.sim != null:
		route = GpsRoute.find(ctx.sim, ctx.player_position(), waypoint)


## The minimap texture exists at 192 x 192, the chips are present, and no text B made is branded.
func self_test() -> Dictionary:
	if model == null or model.texture == null:
		return {"ok": false, "detail": "no minimap texture"}
	var sz := model.texture.get_size()
	if sz != Vector2(192, 192):
		return {"ok": false, "detail": "minimap texture is %dx%d" % [int(sz.x), int(sz.y)]}
	var hud := ctx.hud
	if hud == null or hud.chips == null or hud.chips.chip("pop") == null:
		return {"ok": false, "detail": "chips missing"}
	for t in S.owned_texts(hud):
		if S.branded(t):
			return {"ok": false, "detail": "branded text: " + t}
	return {"ok": true, "detail": "minimap 192x192, %d full repaints (%.1f ms last), chips %s" % [model.full_repaints, model.last_full_ms, hud.chips.text_of("pop")]}


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		model.flush()
	if _route_dirty:
		reroute()


func _full_repaint() -> void:
	if model == null or Engine.get_process_frames() == _painted_frame:
		return
	_painted_frame = Engine.get_process_frames()
	model.full_repaint()


func _on_world_ready() -> void:
	_full_repaint()


func _on_tiles_changed(indices: PackedInt32Array) -> void:
	model.repaint(indices, false)
	_dirty = true
	_route_dirty = has_waypoint


func _on_player_tile(_x: int, _y: int) -> void:
	if has_waypoint:
		reroute()


func _on_territory_changed(mi: int) -> void:
	model.repaint_district(mi, false)
	_dirty = true
