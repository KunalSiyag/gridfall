extends FpFeature
## Traffic and pedestrians on lanes (slice E, docs/fp/slices/E-traffic.md): one road-agent system
## for first person. A right-hand lane graph with traffic lights and tee priority, IDM car
## following, residents' own trips played out from their minds' plans (trip_started), ambient
## commuters and pedestrians around the player, curb parking, buses on seeded lines, trucks and
## emergency crews (CityLife.external), and the ResidentAvatars hooks (ResidentAvatars.external).
## Everyone stops for the player. Motion runs on delta * sim.speed, so pause freezes it.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RD := preload("res://scripts/fp/traffic/render.gd")
const AMB := preload("res://scripts/fp/traffic/ambient.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const FLEETS := preload("res://scripts/fp/traffic/fleets.gd")
const KIT := preload("res://scripts/fp/traffic/mesh_kit.gd")
const MAX_STEP := 1.0 / 30.0
const CAR_PREFIXES := ["sedan", "hatch", "suv", "taxi", "van", "pickup", "coupe"]
## A jump of the player beyond this in one frame is a teleport: the street is refilled around them.
const TELEPORT := 2.0
const WARM_SECONDS := 14.0
const PICK_PX := 26.0
## The traffic photo stands this far from the junction centre along the arm.
const PHOTO_BACK := 1.3

var lanes: LG
var peds: SW
var junctions: JN
var vehicles: VH
var walkers: WK
var render: RD
var ambient: AMB
var trips: TRIPS
var fleets: FLEETS
var clock: float = 0.0
## Test hooks: departure jitter on or off; auto_step false keeps _process from advancing time.
var jitter_enabled: bool = true:
	set(v):
		jitter_enabled = v
		if trips != null:
			trips.jitter_enabled = v
var auto_step: bool = true
## Test hook: false stops the ambient filler (no spawns, no removals).
var ambient_enabled: bool = true
var _props_root: Node3D
var _agents_root: Node3D
var _car_models: Array[int] = []
var _person_models: Array[int] = []
var _vehicle_models: Dictionary = {}
var _bike_model: int = -2
var _last_player := Vector3(INF, INF, INF)
var _force_refill: bool = false
var _static_ver: int = -1
var _static_cam := Vector3(INF, INF, INF)
var _maint_t: float = 0.0
var _stops_sig: String = ""
var _built: bool = false
var _rng := RandomNumberGenerator.new()
## Photo tour: the traffic shot's junction and arm, and the pending staging for the next refill.
var _photo: Dictionary = {}
var _photo_stage: Dictionary = {}
var _budget_frame: int = -1
## agents_near snapshot, built once per frame: the agents and their packed state.
var _snap: Array = []
var _snap_pos := PackedVector3Array()
var _snap_vel := PackedVector3Array()
var _snap_head := PackedFloat32Array()
var _snap_kind := PackedStringArray()
var _snap_frame: int = -1
var _snap_serial: int = 0


func feature_id() -> String:
	return "traffic"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	_props_root = Node3D.new()
	_props_root.name = "StreetProps"
	add_child(_props_root)
	_agents_root = Node3D.new()
	_agents_root.name = "Agents"
	add_child(_agents_root)
	lanes = LG.new()
	peds = SW.new()
	junctions = JN.new()
	vehicles = VH.new()
	walkers = WK.new()
	render = RD.new()
	ambient = AMB.new()
	trips = TRIPS.new()
	fleets = FLEETS.new()
	trips.jitter_enabled = jitter_enabled
	render.setup(_agents_root)
	if ctx.view != null:
		ctx.view.tile_built.connect(_on_tile_built)
		ctx.view.tile_cleared.connect(_on_tile_cleared)
	if ctx.bus != null:
		ctx.bus.conversation_changed.connect(_on_conversation)
	if ctx.residents != null:
		ctx.residents.trip_started.connect(_on_trip_started)
		ctx.residents.resident_departed.connect(_on_departed)
	if ctx.sim != null:
		ctx.sim.event_started.connect(_on_event)
		ctx.sim.event_ended.connect(_on_event)
		ctx.sim.day_started.connect(_on_day_started)


func teardown() -> void:
	if ctx == null:
		return
	if ctx.view != null:
		if ctx.view.tile_built.is_connected(_on_tile_built):
			ctx.view.tile_built.disconnect(_on_tile_built)
		if ctx.view.tile_cleared.is_connected(_on_tile_cleared):
			ctx.view.tile_cleared.disconnect(_on_tile_cleared)
		_attach(false)
	if ctx.bus != null and ctx.bus.conversation_changed.is_connected(_on_conversation):
		ctx.bus.conversation_changed.disconnect(_on_conversation)
	if ctx.residents != null:
		if ctx.residents.trip_started.is_connected(_on_trip_started):
			ctx.residents.trip_started.disconnect(_on_trip_started)
		if ctx.residents.resident_departed.is_connected(_on_departed):
			ctx.residents.resident_departed.disconnect(_on_departed)
	if ctx.sim != null:
		if ctx.sim.event_started.is_connected(_on_event):
			ctx.sim.event_started.disconnect(_on_event)
		if ctx.sim.event_ended.is_connected(_on_event):
			ctx.sim.event_ended.disconnect(_on_event)
		if ctx.sim.day_started.is_connected(_on_day_started):
			ctx.sim.day_started.disconnect(_on_day_started)
	render.clear()
	_built = false


# ------------------------------------------------------------------ world

func on_world_rebuilt() -> void:
	if ctx.sim == null:
		return
	var sim := ctx.sim
	_built = false
	_rng.seed = sim.city_seed * 31337 + 1
	render.clear()
	for c in _agents_root.get_children():
		c.queue_free()
	render.setup(_agents_root)
	_load_models()
	lanes.setup(sim)
	lanes.rebuild_all()
	peds.setup(sim)
	peds.rebuild_all()
	junctions.setup(lanes, _props_root)
	junctions.clock = clock
	vehicles.setup(lanes, junctions, peds, sim.city_seed)
	vehicles.on_arrive = _on_vehicle_arrived
	vehicles.on_removed = _on_vehicle_removed
	walkers.setup(peds, lanes, junctions, vehicles, sim.city_seed)
	walkers.on_removed = func(w: WK.Walker) -> void: render.release_walker(w)
	_static_ver = -1
	ambient.setup(sim, ctx.residents, lanes, peds, vehicles, walkers)
	ambient.car_model = func(seed: int) -> int: return _car_models[absi(seed) % _car_models.size()] if not _car_models.is_empty() else -1
	ambient.person_model = func(seed: int) -> int: return _person_models[absi(seed) % _person_models.size()] if not _person_models.is_empty() else -1
	ambient.dims_of = dims
	ambient.visible = on_screen
	trips.setup(self, sim, ctx.residents, lanes, peds, vehicles, walkers)
	trips.reset()
	fleets.setup(self, sim, lanes, vehicles)
	# Bus-stop curbs stay clear of parking; the bus lines need the final lanes.
	fleets.read_stops(ctx.view)
	lanes.stop_sides = fleets.read_stops(ctx.view)
	ambient.fill_parking()
	lanes.rebuild_all()
	lanes.take_dirty()
	fleets.rebuild_lines(ctx.view)
	_stops_sig = fleets.stops_signature(ctx.view)
	junctions.rebuild_all()
	walkers.rebuild_posts(sim)
	ambient.refresh_tiles()
	_built = true
	_attach(true)
	if ctx.residents != null:
		trips.seed_standing()
	_refill(true)


## Sets (or clears) CityLife.external and ResidentAvatars.external, and re-dispatches crews for
## events CityLife saw before E attached.
func _attach(on: bool) -> void:
	var view := ctx.view
	if view == null:
		return
	if view.life != null and is_instance_valid(view.life):
		view.life.external = self if on else null
		if on:
			view.life.redispatch_events()
	if view.avatars != null and is_instance_valid(view.avatars):
		view.avatars.external = self if on else null


func _on_tile_built(i: int, _holder: Node3D) -> void:
	if ctx.view.in_setup or not _built:
		return
	_tile_changed(i)


func _on_tile_cleared(i: int) -> void:
	if ctx.view.in_setup or not _built:
		return
	_tile_changed(i)


func _tile_changed(i: int) -> void:
	var was_road := lanes.tiles.has(i)
	var is_road := ctx.sim.kind[i] == D.ROAD
	if not was_road and not is_road:
		return
	lanes.rebuild_around(i)
	peds.rebuild_around(i)
	junctions.build_props(i)
	for n: int in lanes.neighbours(i):
		junctions.build_props(n)
	walkers.rebuild_posts(ctx.sim)
	ambient.refresh_tiles()
	_after_lane_change()


## Smooths vehicles on rebuilt tiles and moves any car whose slot vanished.
func _after_lane_change() -> void:
	var dirty := lanes.take_dirty()
	vehicles.on_lanes_rebuilt(dirty)
	for c: VH.Car in vehicles.cars.duplicate():
		if c.parked and c.slot_tile >= 0 and dirty.has(c.slot_tile) and not lanes.slot_valid(c.slot_tile, c.slot_k):
			if c.role == "decor":
				vehicles.remove(c)
			else:
				lanes.set_slot(c.slot_tile, c.slot_k, "")
				c.slot_tile = -1
	vehicles.on_lanes_rebuilt(lanes.take_dirty())


func _on_event(_ev: Dictionary) -> void:
	if _built:
		lanes.refresh_blocked()


func _on_day_started(_day: int) -> void:
	if _built and ctx.residents != null:
		trips.on_day_started()
		_after_lane_change()


func _on_trip_started(id: String, from_i: int, to_i: int, mode: String) -> void:
	if not _built:
		return
	trips.on_trip_started(id, from_i, to_i, mode)
	_after_lane_change()


func _on_departed(r: Dictionary, _reason: String) -> void:
	if _built:
		trips.on_departed(r)


func _on_conversation(id: String, active: bool) -> void:
	if _built:
		trips.hold(id, active)


func _on_vehicle_arrived(c: VH.Car) -> void:
	if c.role == "resident":
		trips.on_car_arrived(c)
		_after_lane_change()


func _on_vehicle_removed(c: VH.Car) -> void:
	render.release_car(c)


# ------------------------------------------------------------------ time

func _process(delta: float) -> void:
	if ctx == null or ctx.sim == null or not _built:
		return
	var p := ctx.player_position()
	if _force_refill or (_last_player.x < INF and p.distance_to(_last_player) > TELEPORT):
		_force_refill = false
		_refill(true)
	_last_player = p
	if auto_step:
		var dt := delta * float(ctx.sim.speed)
		while dt > 0.0:
			var h := minf(dt, MAX_STEP)
			step(h)
			dt -= h
	sync_visuals(delta)


## Advances everything by dt seconds of game-scaled time (test hook; _process calls it in steps
## of at most 1/30 s).
func step(dt: float) -> void:
	if not _built or dt <= 0.0:
		return
	# A* budget per frame; a test driving step() itself gets a fresh budget per call.
	var frame := Engine.get_process_frames()
	if frame != _budget_frame or not auto_step:
		_budget_frame = frame
		fleets.astar_left = FLEETS.ASTAR_PER_FRAME
	_snap_frame = -1
	clock += dt
	junctions.clock = clock
	var pp := ctx.player_position()
	var has_player := ctx.player != null and is_instance_valid(ctx.player)
	vehicles.player_pos = pp
	vehicles.player_on = has_player
	walkers.player_pos = pp
	walkers.player_on = has_player
	vehicles.step(dt)
	walkers.step(dt)
	trips.step(dt)
	fleets.step(dt)
	_maint_t -= dt
	if _maint_t <= 0.0:
		_maint_t = 0.5
		_maintain(false)


## Far/near transitions, ambient top-up, stop changes.
func _maintain(sync: bool) -> void:
	var p := ctx.player_position()
	var r := WS.TRAFFIC_RADIUS
	for c: VH.Car in vehicles.cars.duplicate():
		if c.parked or c.dead or c.role == "ambient" or c.role == "decor":
			continue
		var d := Vector2(c.pos.x - p.x, c.pos.z - p.z).length()
		if not c.far and d > r + 0.5 and not on_screen(c.pos):
			vehicles.make_far(c)
		elif c.far and d < r - 0.5:
			vehicles.make_near(c)
		if c.stuck and not on_screen(c.pos):
			_drop_stuck(c)
	for w: WK.Walker in walkers.walkers:
		if w.role == "resident":
			w.far = Vector2(w.pos.x - p.x, w.pos.z - p.z).length() > r
	if ambient_enabled:
		ambient.maintain(p, _player_fwd(), sync)
	var sig := fleets.stops_signature(ctx.view)
	if sig != _stops_sig:
		_stops_sig = sig
		lanes.stop_sides = fleets.read_stops(ctx.view)
		lanes.rebuild_all()
		fleets.rebuild_lines(ctx.view)
		_after_lane_change()


func _drop_stuck(c: VH.Car) -> void:
	if c.owner is TRIPS.Trip:
		trips.complete_now(c.owner)
	if not c.dead and not c.parked:
		vehicles.remove(c)


## Fills the street around the player now (first fill, load, teleport): ambient traffic out of the
## camera, then a short simulated warm-up so queues and spacing look natural.
func _refill(warm: bool) -> void:
	if not _built:
		return
	_last_player = ctx.player_position()
	_maintain(true)
	if warm:
		if not _photo_stage.is_empty():
			var i := int(_photo_stage["tile"])
			var axis_in := 0 if int(_photo_stage["arm"]) % 2 == 0 else 1
			var want := (JN.T_GREEN + JN.T_AMBER + JN.T_ALLRED) * float(1 - axis_in) + 5.0
			var t_end := fposmod(clock + WARM_SECONDS + junctions.offset(i), JN.CYCLE)
			clock += fposmod(want - t_end, JN.CYCLE)
			junctions.clock = clock
			_photo_stage = {}
		var saved := clock
		for _k in range(int(WARM_SECONDS / 0.1)):
			step(0.1)
		clock = saved + WARM_SECONDS
		junctions.clock = clock


func _player_fwd() -> Vector3:
	if ctx.player != null and is_instance_valid(ctx.player):
		return ctx.player.forward()
	return Vector3(0, 0, -1)


# ------------------------------------------------------------------ visuals

## Draws every agent (full models near, MultiMesh LOD far) and updates lamp states. Parked cars
## are redrawn only when the parked set changes or the camera moves a little.
func sync_visuals(delta: float) -> void:
	var cam := _camera_pos()
	if vehicles.parked_version != _static_ver or cam.distance_to(_static_cam) > 0.25:
		_static_ver = vehicles.parked_version
		_static_cam = cam
		render.begin_static()
		for c: VH.Car in vehicles.cars:
			if c.dead or not c.parked:
				continue
			if c.slot_tile < 0:
				render.release_car(c)
				continue
			render.draw_parked(c, vehicles.draw_xform(c), cam.distance_to(c.pos), WS.VIS_CAR)
		render.finish_static()
	render.begin(delta)
	for c: VH.Car in vehicles.cars:
		if c.dead or c.parked:
			continue
		if c.far:
			render.release_car(c)
			continue
		var siren := ""
		if c.role == "crew" and c.owner is Dictionary and str((c.owner as Dictionary).get("phase", "")) != "leaving":
			siren = str((c.owner as Dictionary).get("kind", ""))
		var brake := c.a < -0.8 * WS.M or c.v < 0.05 * WS.M
		render.draw_car(c, vehicles.draw_xform(c), cam.distance_to(c.pos), WS.VIS_CAR, brake, siren, c.wheel_spin)
	for w: WK.Walker in walkers.walkers:
		if w.dead or w.state == "hidden" or w.far:
			render.release_walker(w)
			continue
		walkers.ease_visuals(w, delta)
		render.draw_walker(w, walkers.draw_xform(w), cam.distance_to(w.pos), WS.VIS_PERSON, walkers.draw_phase(w))
	render.finish()
	render.set_glow(_night())
	junctions.update_lamps(ctx.player_position(), WS.VIS_PROP + 1.0)


## 0 by day, 1 at night (the sky director's darkness; 0 without one).
func _night() -> float:
	if ctx.sky != null and is_instance_valid(ctx.sky):
		return clampf(float(ctx.sky.night), 0.0, 1.0)
	return 0.0


func _camera() -> Camera3D:
	if ctx.player != null and is_instance_valid(ctx.player) and ctx.player.camera != null:
		return ctx.player.camera
	return null


func _camera_pos() -> Vector3:
	var cam := _camera()
	if cam != null and cam.is_inside_tree():
		return cam.global_position
	return ctx.player_position() + Vector3(0, WS.EYE, 0)


## True when p could be on screen now (inside the camera frustum and within car range).
func on_screen(p: Vector3) -> bool:
	var cam := _camera()
	if cam == null or not cam.is_inside_tree():
		return false
	var cp := cam.global_position
	var d := cp.distance_to(p)
	if d > WS.VIS_CAR:
		return false
	if d < 0.08:
		return true
	return cam.is_position_in_frustum(p) or cam.is_position_in_frustum(p + Vector3(0, 0.1, 0))


## True when p is beyond the traffic radius of the player.
func is_far(p: Vector3) -> bool:
	var pp := ctx.player_position()
	return Vector2(p.x - pp.x, p.z - pp.z).length() > WS.TRAFFIC_RADIUS


func player_dist(p: Vector2) -> float:
	var pp := ctx.player_position()
	return p.distance_to(Vector2(pp.x, pp.z))


# ------------------------------------------------------------------ models

func _load_models() -> void:
	_car_models.clear()
	_person_models.clear()
	_vehicle_models.clear()
	_bike_model = -2
	var v2 := _list(AP.VEHICLES_V2_DIR, CAR_PREFIXES)
	var sc := WS.VEHICLE_V2_SCALE if not v2.is_empty() else WS.VEHICLE_SCALE
	for path: String in (v2 if not v2.is_empty() else _list(AP.VEHICLES_LEGACY_DIR, CAR_PREFIXES)):
		var m := render.model_for(path, sc)
		if m >= 0:
			_car_models.append(m)
	for path: String in _list(AP.PEOPLE_LEGACY_DIR, ["person"]):
		var m := render.model_for(path, WS.PEOPLE_SCALE, true)
		if m >= 0:
			_person_models.append(m)


static func _list(dir_path: String, prefixes: Array) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		var n := f.trim_suffix(".import").trim_suffix(".remap")
		if not n.ends_with(".glb") or n.ends_with("_lod1.glb"):
			continue
		for p: String in prefixes:
			if n.begins_with(p) and not out.has(dir_path + n):
				out.append(dir_path + n)
				break
	out.sort()
	return out


## Model of a fleet vehicle kind (bus, truck, garbage_truck, firetruck, ambulance, police).
func vehicle_model(kind: String) -> int:
	if _vehicle_models.has(kind):
		return _vehicle_models[kind]
	var names := {"truck": ["truck", "van_white"], "garbage_truck": ["garbage_truck", "truck"], "ambulance": ["ambulance", "van_white"],
		"police": ["police", "sedan_white"], "firetruck": ["firetruck", "truck"], "bus": ["bus"]}
	var m := -1
	for n: String in names.get(kind, [kind]):
		for d: Array in [[AP.VEHICLES_V2_DIR, WS.VEHICLE_V2_SCALE], [AP.VEHICLES_LEGACY_DIR, WS.VEHICLE_SCALE]]:
			var path := str(d[0]) + n + ".glb"
			if ResourceLoader.exists(path):
				m = render.model_for(path, float(d[1]))
				if m >= 0:
					break
		if m >= 0:
			break
	_vehicle_models[kind] = m
	return m


## A resident's own car model: the same pick as ResidentAvatars (hash of the id over the list).
func car_model_for(rid: String) -> int:
	if _car_models.is_empty():
		return -1
	return _car_models[absi(hash(rid)) % _car_models.size()]


func person_model_for(rid: String) -> int:
	if _person_models.is_empty():
		return -1
	return _person_models[absi(hash(rid)) % _person_models.size()]


## World size (x width, y height, z length) of a model.
func dims(m: int) -> Vector3:
	var mo := render.model(m)
	return mo.size if mo != null else Vector3(0.105, 0.075, 0.24)


## A cyclist: H's bicycle when present, else a procedural bicycle and rider (one mesh).
func bike_model() -> int:
	if _bike_model != -2:
		return _bike_model
	if AP.load_scene(AP.BICYCLE) != null:
		_bike_model = render.model_for(AP.BICYCLE, WS.VEHICLE_V2_SCALE)
		return _bike_model
	var M := WS.M
	var kit: KIT = KIT.new()
	kit.begin()
	var frame := Color(0.12, 0.35, 0.6)
	var tyre := Color(0.05, 0.05, 0.05)
	for z: float in [-0.52, 0.52]:
		var wx := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(0.02 * M, 0.34 * M, z * M))
		kit.cyl(wx, 0.34 * M, 0.34 * M, 0.04 * M, tyre, 14)
	kit.box(Transform3D(Basis(Vector3(1, 0, 0), -0.35), Vector3(0, 0.55 * M, 0.02 * M)), Vector3(0.04 * M, 0.04 * M, 0.95 * M), frame)
	kit.box(Transform3D(Basis(), Vector3(0, 0.62 * M, -0.12 * M)), Vector3(0.04 * M, 0.5 * M, 0.04 * M), frame)
	kit.box(Transform3D(Basis(), Vector3(0, 0.95 * M, 0.42 * M)), Vector3(0.5 * M, 0.03 * M, 0.03 * M), Color(0.2, 0.2, 0.2))
	var shirt := Color(0.75, 0.2, 0.15)
	var pants := Color(0.12, 0.13, 0.18)
	var skin := Color(0.85, 0.66, 0.52)
	kit.box(Transform3D(Basis(Vector3(1, 0, 0), 0.25), Vector3(0.08 * M, 0.7 * M, 0.0)), Vector3(0.13 * M, 0.55 * M, 0.14 * M), pants)
	kit.box(Transform3D(Basis(Vector3(1, 0, 0), -0.25), Vector3(-0.08 * M, 0.62 * M, -0.05 * M)), Vector3(0.13 * M, 0.55 * M, 0.14 * M), pants)
	kit.box(Transform3D(Basis(Vector3(1, 0, 0), 0.55), Vector3(0, 1.22 * M, 0.08 * M)), Vector3(0.38 * M, 0.6 * M, 0.22 * M), shirt)
	for sx: float in [-0.17, 0.17]:
		kit.box(Transform3D(Basis(Vector3(1, 0, 0), 1.0), Vector3(sx * M, 1.18 * M, 0.3 * M)), Vector3(0.08 * M, 0.5 * M, 0.08 * M), shirt)
	kit.cyl(Transform3D(Basis(), Vector3(0, 1.5 * M, 0.26 * M)), 0.11 * M, 0.1 * M, 0.22 * M, skin, 10)
	kit.cyl(Transform3D(Basis(), Vector3(0, 1.66 * M, 0.25 * M)), 0.13 * M, 0.06 * M, 0.08 * M, Color(0.9, 0.85, 0.1), 10)
	_bike_model = render.model_proc("cyclist", kit.commit(), Vector3(0.6 * M, 1.8 * M, 1.8 * M))
	return _bike_model


# ------------------------------------------------------------------ helpers for trips and fleets

## Where a person enters or leaves lot i: H's Door_<n> empty when the building has one, else the
## middle of its front edge (facing its frontage road).
func door_point(lot: int) -> Vector3:
	if lot < 0:
		return ctx.player_position()
	var c := Vector3(D.tx(lot), 0, D.ty(lot))
	if ctx.view != null:
		var holder := ctx.view.tile_holder(lot)
		if holder != null and is_instance_valid(holder):
			var doors := holder.find_children(AP.DOOR_SPOT_PREFIX + "*", "Node3D", true, false)
			if not doors.is_empty() and (doors[0] as Node3D).is_inside_tree():
				return (doors[0] as Node3D).global_position
	if ctx.sim.kind[lot] == D.ROAD:
		return Vector3(c.x, WS.SIDEWALK_TOP, c.z)
	var fr := ctx.directory.frontage(lot) if ctx.directory != null else -1
	if fr < 0:
		return Vector3(c.x, WS.LOT_TOP, c.z)
	var d := Vector3(D.tx(fr) - D.tx(lot), 0, D.ty(fr) - D.ty(lot))
	var p := c + d * 0.47
	p.y = _ground(p, WS.LOT_TOP)
	return p


func _ground(p: Vector3, fallback: float) -> float:
	if ctx.collision != null:
		var y := ctx.collision.ground_height(p)
		if not is_nan(y):
			return y
	return fallback


func place_label(lot: int) -> String:
	if ctx.directory == null or lot < 0:
		return ""
	return ctx.directory.place_label(lot)


func street_label(tile: int) -> String:
	if ctx.directory == null or tile < 0:
		return ""
	var s := ctx.directory.street_name(tile)
	return s if not s.is_empty() else ctx.directory.place_label(tile)


## Where a resident stands outdoors at lot: [pos, yaw] in a small group (they face its middle).
func outdoor_spot(lot: int, rid: String) -> Array:
	var fr := ctx.directory.frontage(lot) if ctx.directory != null else -1
	if fr < 0:
		return []
	var c := Vector3(D.tx(lot), 0, D.ty(lot))
	var to_road := Vector3(D.tx(fr) - D.tx(lot), 0, D.ty(fr) - D.ty(lot))
	var side := Vector3(-to_road.z, 0, to_road.x)
	var n := 0
	for k: String in trips.standing.keys():
		var w: WK.Walker = trips.standing[k]
		if w != null and Vector2(w.pos.x - c.x, w.pos.z - c.z).length() < 0.9:
			n += 1
	var grp := n / 3
	var mem := n % 3
	var base: Vector3
	var kind := ctx.sim.kind[lot]
	if kind == D.PARK or kind == D.FOREST or kind == D.STADIUM:
		base = c + to_road * 0.28 + side * (fposmod(float(grp) * 0.17 + 0.1, 0.6) - 0.3)
	else:
		base = c + to_road * (1.0 - 0.43) + side * (fposmod(float(grp) * 0.13 + 0.05, 0.6) - 0.3)
	var a := float(mem) * TAU / 3.0 + float(absi(hash(rid)) % 100) * 0.01
	var p := base + Vector3(cos(a), 0, sin(a)) * (0.55 * WS.M)
	p.y = _ground(p, WS.SIDEWALK_TOP)
	var face := base - p
	return [p, atan2(face.x, face.z)]


## A spot for a fleet vehicle at tile `start` (or anywhere fitting the spawn rules): [lane, s] or [].
func spawn_spot_near(start: Vector2i, length: float) -> Array:
	var p := ctx.player_position()
	if D.in_bounds(start.x, start.y):
		var i := D.idx(start.x, start.y)
		var t: LG.TileInfo = lanes.info(i)
		var dx := float(start.x) - p.x
		var dz := float(start.y) - p.z
		var d2 := dx * dx + dz * dz
		if t != null and d2 <= WS.TRAFFIC_RADIUS * WS.TRAFFIC_RADIUS and d2 >= AMB.MIN_SPAWN * AMB.MIN_SPAWN:
			for l: LG.Lane in t.lanes:
				if (l.kind == LG.STRAIGHT or l.kind == LG.CORNER) and l.length > length + 0.05:
					var s := l.length * 0.5 + length * 0.5
					var at := lanes.pos_at(l, s)
					if vehicles.fits(l, s, length) and not on_screen(Vector3(at.x, 0.05, at.y)):
						return [l, s]
	var fwd := _player_fwd()
	for _k in range(24):
		var i := ambient._pick_tile(p, fwd, false)
		if i < 0:
			continue
		var t: LG.TileInfo = lanes.info(i)
		if t == null:
			continue
		for l: LG.Lane in t.lanes:
			if l.kind == LG.STRAIGHT and l.length > length + 0.05:
				var s := _rng.randf_range(length + 0.02, l.length - 0.02)
				var at := lanes.pos_at(l, s)
				if vehicles.fits(l, s, length) and not on_screen(Vector3(at.x, 0.05, at.y)):
					return [l, s]
	return []


## A resident with `job` who is at work, not on a trip and not already driving a fleet vehicle.
func free_worker(job: String) -> String:
	if ctx.residents == null:
		return ""
	var busy := {}
	for c: VH.Car in vehicles.cars:
		if c.role in ["bus", "truck", "garbage", "crew"] and not c.driver_id.is_empty():
			busy[c.driver_id] = true
	for r: Dictionary in ctx.residents.people:
		var rid := str(r["id"])
		if str(r.get("job_title", "")) != job or str(r.get("state", "")) != "work":
			continue
		if busy.has(rid) or trips.trips.has(rid):
			continue
		return rid
	return ""


func bus_choice(seq: Array[int], dest: int) -> Array:
	return fleets.bus_choice(seq, dest)


func bus_at(bus: VH.Car, line: int, tile: int) -> void:
	trips.on_bus_at(bus, line, tile)


## Where people wait at the bus stop on tile i: on the walking band in front of the shelter.
func stop_point(i: int) -> Vector3:
	var side: int = fleets.stop_sides.get(i, 0)
	var rd := lanes.run_dir(i)
	var r := Vector2(-rd.y, rd.x) * (1.0 if side == 0 else -1.0)
	var p := Vector2(D.tx(i), D.ty(i)) + r * SW.LAT + rd * (0.06 if side == 0 else -0.06)
	return Vector3(p.x, WS.SIDEWALK_TOP, p.y)


# ------------------------------------------------------------------ CityLife.external

## Adds one vehicle of a fleet (bus, truck, garbage_truck) when its own rules allow.
func spawn_fleet(kind: String, start: Vector2i) -> void:
	if _built:
		fleets.spawn_fleet(kind, start)


## Sends an emergency crew of `kind` from road tile station to road tile target.
func dispatch_crew(kind: String, station: Vector2i, target: Vector2i) -> void:
	if _built:
		fleets.dispatch_crew(kind, station, target)


## Current size of a fleet (CityLife's census compares it with its target).
func fleet_size(kind: String) -> int:
	return fleets.fleet_size(kind) if _built else 0


## {buses, trucks, crews, boats, aircraft}: road fleets from E, boats and aircraft from CityLife.
func vehicle_counts() -> Dictionary:
	var out := {"buses": 0, "trucks": 0, "crews": 0, "boats": 0, "aircraft": 0}
	if _built:
		out["buses"] = fleets.count("bus")
		out["trucks"] = fleets.count("truck") + fleets.count("garbage")
		out["crews"] = fleets.count("crew")
	if ctx.view != null and ctx.view.life != null and is_instance_valid(ctx.view.life):
		out["boats"] = ctx.view.life.boat_count()
		out["aircraft"] = ctx.view.life.aircraft_count()
	return out


# ------------------------------------------------------------------ ResidentAvatars.external

## Residents.resident_moved, forwarded (state only: trips spawn from trip_started).
func on_resident_moved(r: Dictionary) -> void:
	if _built:
		trips.on_moved(r)


## Live position of a resident while drawn; else the tile they are at.
func position_of(id: String) -> Vector3:
	if _built:
		var p := trips.live_position(id)
		if not is_nan(p.x):
			return p
	var r := ctx.residents.find(id) if ctx.residents != null else {}
	if r.is_empty():
		return Vector3(15.5, 0, 15.5)
	var at := int(r["at"])
	return Vector3(D.tx(at), 0, D.ty(at))


## The drawn resident closest to screen_pos within 26 px of camera cam, or "".
func avatar_pick(screen_pos: Vector2, cam: Camera3D) -> String:
	if cam == null or not _built:
		return ""
	var best := ""
	var bd := PICK_PX
	for e: Dictionary in visible_near(cam.global_position, WS.VIS_PERSON):
		var wp: Vector3 = e["pos"] + Vector3(0, 0.08, 0)
		if cam.is_position_behind(wp):
			continue
		var d := cam.unproject_position(wp).distance_to(screen_pos)
		if d < bd:
			bd = d
			best = str(e["id"])
	return best


## {walking, driving, standing, total} for the HUD and the smoke prints.
func avatar_counts() -> Dictionary:
	var walking := 0
	var driving := 0
	var standing := 0
	if _built:
		for tr: TRIPS.Trip in trips.trips.values():
			if trips.vehicle_of(tr.rid) != null:
				driving += 1
			elif tr.walker != null and not tr.walker.dead:
				if tr.walker.state == "stand" or tr.walker.state == "wait":
					standing += 1
				else:
					walking += 1
		standing += trips.standing.size()
	var total := ctx.residents.people.size() if ctx.residents != null else 0
	return {"walking": walking, "driving": driving, "standing": standing, "total": total}


# ------------------------------------------------------------------ public API (contract)

## Agents near p for the minimap and audio (moving vehicles and people on foot; parked cars are
## left out): [{id, pos, vel, speed, kind, driver_id, heading, stalled_s}]. heading follows S0 §11
## (forward = (-sin h, 0, -cos h)), so it holds for stopped agents too; vel is u/s. The entries
## are each agent's own dictionary, refreshed once per frame: read them now, copy one to keep it.
func agents_near(p: Vector3, r: float) -> Array:
	var out: Array = []
	if not _built:
		return out
	_refresh_snapshot()
	var r2 := r * r
	for k in range(_snap_pos.size()):
		if _snap_pos[k].distance_squared_to(p) <= r2:
			out.append(_info(k))
	return out


## The cheap form of agents_near for per-frame consumers: parallel packed arrays
## {"pos": PackedVector3Array, "vel": PackedVector3Array, "heading": PackedFloat32Array,
##  "kind": PackedStringArray} of the agents within r of p (same conventions, no dictionaries).
func agents_packed(p: Vector3, r: float) -> Dictionary:
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var head := PackedFloat32Array()
	var kind := PackedStringArray()
	if _built:
		_refresh_snapshot()
		var r2 := r * r
		for k in range(_snap_pos.size()):
			if _snap_pos[k].distance_squared_to(p) <= r2:
				pos.append(_snap_pos[k])
				vel.append(_snap_vel[k])
				head.append(_snap_head[k])
				kind.append(_snap_kind[k])
	return {"pos": pos, "vel": vel, "heading": head, "kind": kind}


## Positions, velocities, headings and kinds of every moving agent, at most once per frame (and
## again after a step).
func _refresh_snapshot() -> void:
	var fr := Engine.get_process_frames()
	if fr == _snap_frame:
		return
	_snap_frame = fr
	_snap_serial += 1
	_snap.clear()
	_snap_pos.clear()
	_snap_vel.clear()
	_snap_head.clear()
	_snap_kind.clear()
	for c: VH.Car in vehicles.cars:
		if c.parked or c.far or c.dead:
			continue
		_snap.append(c)
		_snap_pos.append(c.pos + c.vis_off)
		_snap_vel.append(c.vel)
		_snap_head.append(wrapf(c.yaw + c.vis_yaw + PI, -PI, PI))
		_snap_kind.append("pedestrian" if c.kind == "bike" else c.kind)
	for w: WK.Walker in walkers.walkers:
		if w.dead or w.far:
			continue
		_snap.append(w)
		_snap_pos.append(w.pos + w.vis_off)
		_snap_vel.append(w.vel)
		_snap_head.append(wrapf(w.yaw + PI, -PI, PI))
		_snap_kind.append("pedestrian")


## Snapshot entry k as the agent's own agents_near dictionary (refreshed once per snapshot).
func _info(k: int) -> Dictionary:
	var a: Variant = _snap[k]
	var d: Dictionary = a.info
	if a.info_serial == _snap_serial:
		return d
	a.info_serial = _snap_serial
	d["pos"] = _snap_pos[k]
	d["vel"] = _snap_vel[k]
	d["heading"] = _snap_head[k]
	d["kind"] = _snap_kind[k]
	if a is VH.Car:
		var c: VH.Car = a
		d["id"] = c.id
		d["speed"] = c.v
		d["driver_id"] = c.driver_id
		d["stalled_s"] = c.stalled_s
	else:
		var w: WK.Walker = a
		d["id"] = 1000000 + w.id
		d["speed"] = w.v
		d["driver_id"] = w.resident_id
		d["stalled_s"] = w.stalled_s
	return d


## Visible named residents near p (on foot, in a vehicle, or standing outdoors; never indoors).
func visible_near(p: Vector3, r: float) -> Array:
	var out: Array = []
	if not _built:
		return out
	var r2 := r * r
	var seen := {}
	for w: WK.Walker in walkers.walkers:
		if w.dead or w.resident_id.is_empty() or w.state == "hidden":
			continue
		var q := w.pos + w.vis_off
		if q.distance_squared_to(p) <= r2 and not seen.has(w.resident_id):
			out.append({"id": w.resident_id, "pos": q})
			seen[w.resident_id] = true
	for tr: TRIPS.Trip in trips.trips.values():
		if seen.has(tr.rid):
			continue
		var c := trips.vehicle_of(tr.rid)
		if c != null:
			var q := c.pos + c.vis_off
			if q.distance_squared_to(p) <= r2:
				out.append({"id": tr.rid, "pos": q})
	return out


func is_resident_visible(id: String) -> bool:
	return _built and not is_nan(trips.live_position(id).x)


## Interaction pick (S0 §10): residents on foot, ambient pedestrians, vehicles (parked included).
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	if not _built:
		return {}
	var best := {}
	var bt := max_dist
	var d := dir.normalized()
	for w: WK.Walker in walkers.walkers:
		if w.dead or w.far or w.state == "hidden":
			continue
		if w.pos.distance_to(origin) > max_dist + 0.1:
			continue
		var t := _ray_box(origin, d, Transform3D(Basis(Vector3.UP, w.yaw), w.pos), Vector3(0.32 * WS.M, 0.0, 0.25 * WS.M), 1.8 * WS.M)
		if t >= 0.0 and t < bt:
			bt = t
			best = _walker_target(w, t)
	for c: VH.Car in vehicles.cars:
		if c.dead or c.far or (c.parked and c.slot_tile < 0):
			continue
		if c.pos.distance_to(origin) > max_dist + 0.4:
			continue
		var t := _ray_box(origin, d, vehicles.draw_xform(c), Vector3(c.half_w, 0.0, c.length * 0.5), c.height)
		if t >= 0.0 and t < bt:
			bt = t
			best = _car_target(c, t)
	if not best.is_empty():
		best["pos"] = origin + d * bt
	return best


func _walker_target(w: WK.Walker, t: float) -> Dictionary:
	var tile := -1
	var px := roundi(w.pos.x)
	var pz := roundi(w.pos.z)
	if D.in_bounds(px, pz):
		tile = D.idx(px, pz)
	if not w.resident_id.is_empty() and ctx.residents != null:
		var r := ctx.residents.find(w.resident_id)
		if not r.is_empty():
			return {"kind": "resident", "id": w.resident_id, "tile": tile, "dist": t,
				"label": "Talk to %s, %s" % [str(r["name"]), str(r["job_title"])], "data": {"state": str(r.get("state", ""))}}
	return {"kind": "pedestrian", "id": "p%d" % w.id, "tile": tile, "dist": t, "label": "a pedestrian", "data": {}}


func _car_target(c: VH.Car, t: float) -> Dictionary:
	var tile := -1
	var px := roundi(c.pos.x)
	var pz := roundi(c.pos.z)
	if D.in_bounds(px, pz):
		tile = D.idx(px, pz)
	var label := c.label if not c.label.is_empty() else "a commuter"
	var mood: Variant = ""
	if not c.driver_id.is_empty() and ctx.residents != null:
		var r := ctx.residents.find(c.driver_id)
		if not r.is_empty():
			mood = float(r.get("mood", 0.0))
			if c.role == "resident":
				label = "%s, %s" % [str(r["name"]), str(r["job_title"])]
	var state := c.state if not c.state.is_empty() else ("parked" if c.parked else "driving")
	return {"kind": "vehicle", "id": "v%d" % c.id, "tile": tile, "dist": t, "label": label,
		"data": {"driver_id": c.driver_id, "state": state, "dest_label": c.dest_label, "mood": mood}}


## Distance along the ray (o, unit d) to an oriented box whose bottom centre is xf's origin (half
## extents he in x and z, height h), or -1 when it misses.
static func _ray_box(o: Vector3, d: Vector3, xf: Transform3D, he: Vector3, h: float) -> float:
	var inv := xf.affine_inverse()
	var lo := inv * o
	var ld := inv.basis * d
	var mn := Vector3(-he.x, 0.0, -he.z)
	var mx := Vector3(he.x, h, he.z)
	var t0 := -INF
	var t1 := INF
	for a in range(3):
		if absf(ld[a]) < 1e-9:
			if lo[a] < mn[a] or lo[a] > mx[a]:
				return -1.0
			continue
		var ta := (mn[a] - lo[a]) / ld[a]
		var tb := (mx[a] - lo[a]) / ld[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t1 < maxf(t0, 0.0):
		return -1.0
	return maxf(t0, 0.0)


## Optional, for A: world AABBs of stopped vehicles near p (parked cars included).
func blockers_near(p: Vector3, r: float) -> Array:
	var out: Array = []
	if not _built:
		return out
	for c: VH.Car in vehicles.cars:
		if c.dead or c.far or (c.parked and c.slot_tile < 0):
			continue
		if c.v > 0.1 * WS.M or c.pos.distance_to(p) > r + 0.3:
			continue
		out.append(vehicles.aabb(c))
	return out


## The traffic-light pole on cross tile i at corner (0..3 = NE, SE, SW, NW), or null.
func light_pole(i: int, corner: int) -> Node3D:
	return junctions.light_pole(i, corner) if _built else null


## Live head anchor of resident id while drawn (else above where they are).
func anchor_of(id: String) -> Vector3:
	if _built:
		var a := trips.anchor(id)
		if not is_nan(a.x):
			return a
	return position_of(id) + Vector3(0, TRIPS.HEAD, 0)


## Animated-people stats for G2's bench (stage E2; legacy static people until HC lands).
func anim_stats() -> Dictionary:
	return {"t0": 0, "t1": 0, "t2": 0, "t3": 0, "anim_us": 0.0, "char_draws": render.draws_people if render != null else 0}


# ------------------------------------------------------------------ save, smoke, photos

func to_dict() -> Dictionary:
	if not _built:
		return {}
	return {"parked": trips.parked_table()}


func from_dict(d: Dictionary) -> void:
	if not _built:
		return
	for tr: TRIPS.Trip in trips.trips.values():
		trips.complete_now(tr)
	var parked: Variant = d.get("parked", {})
	if typeof(parked) == TYPE_DICTIONARY and not (parked as Dictionary).is_empty():
		trips.restore_parked(parked)
	_after_lane_change()
	_refill(true)


func self_test() -> Dictionary:
	if not _built:
		return {"ok": false, "detail": "not built"}
	var p := ctx.player_position()
	var r2 := WS.TRAFFIC_RADIUS * WS.TRAFFIC_RADIUS
	var cars := 0
	var people := 0
	for c: VH.Car in vehicles.cars:
		if not c.dead and Vector2(c.pos.x - p.x, c.pos.z - p.z).length_squared() <= r2:
			cars += 1
	for w: WK.Walker in walkers.walkers:
		if not w.dead and Vector2(w.pos.x - p.x, w.pos.z - p.z).length_squared() <= r2:
			people += 1
	var ok := not lanes.is_empty() and cars >= 1 and people >= 1
	return {"ok": ok, "detail": "lanes=%d cars=%d people=%d lines=%d" % [lanes.lane_count(), cars, people, fleets.lines.size()]}


## The "traffic" shot: the most built-up cross tile with lights, seen at eye height from the
## sidewalk of one of its arms, 1.3 tiles back, beside the inbound lane: the queue at the light,
## the zebra in front of it, the poles and the cross traffic.
func photo_shots() -> Array:
	if not _built:
		return []
	var best := -1
	var bn := -1
	var best_arm := -1
	for i: int in lanes.tiles.keys():
		var t: LG.TileInfo = lanes.tiles[i]
		if not t.lights:
			continue
		var arm := _photo_arm(i)
		if arm < 0:
			continue
		var n := 0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var x := D.tx(i) + dx
				var y := D.ty(i) + dy
				if D.in_bounds(x, y) and D.is_zone(ctx.sim.kind[D.idx(x, y)]):
					n += 1 + ctx.sim.level[D.idx(x, y)]
		if n > bn:
			bn = n
			best = i
			best_arm = arm
	if best < 0:
		return []
	_photo = {"tile": best, "arm": best_arm}
	var a := LG.DIRS[best_arm]
	var right := Vector2(a.y, -a.x)
	var c := Vector2(D.tx(best), D.ty(best))
	var at := c + a * PHOTO_BACK + right * SW.LAT
	var look := c - right * 0.05 - at
	var pos := Vector3(at.x, 0, at.y)
	pos.y = _ground(pos, WS.SIDEWALK_TOP)
	return [{"name": "traffic", "pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.y)), "pitch": -2.0, "hour": 10.5, "prepare": "photo_prepare"}]


## The arm of cross tile i to shoot from: two straight tiles beyond it (the camera stands on a
## plain sidewalk), preferring the one with the most built-up lots beside it; -1 when none.
func _photo_arm(i: int) -> int:
	var best := -1
	var bn := -1
	for e in range(4):
		var n1 := lanes.across(i, e)
		var t1: LG.TileInfo = lanes.info(n1) if n1 >= 0 else null
		if t1 == null or t1.piece != "straight" or t1.bridge:
			continue
		var n2 := lanes.across(n1, e)
		var t2: LG.TileInfo = lanes.info(n2) if n2 >= 0 else null
		if t2 == null or t2.piece != "straight":
			continue
		var n := 0
		for tile: int in [n1, n2]:
			for side: Vector2 in [Vector2(LG.DIRS[e].y, -LG.DIRS[e].x), Vector2(-LG.DIRS[e].y, LG.DIRS[e].x)]:
				var x := D.tx(tile) + int(side.x)
				var y := D.ty(tile) + int(side.y)
				if D.in_bounds(x, y) and D.is_zone(ctx.sim.kind[D.idx(x, y)]):
					n += 1 + ctx.sim.level[D.idx(x, y)]
		if n > bn:
			bn = n
			best = e
	return best


## Photo tour hook: refill the street around the next shot (the tour holds sim speed 0) and time
## the warm-up so it ends with the shot's approach on red and the cross street green, 5 s in:
## the queue has formed and people are on the zebra in front of it.
func photo_prepare() -> void:
	_force_refill = true
	_photo_stage = _photo.duplicate()
