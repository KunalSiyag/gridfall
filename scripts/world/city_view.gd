class_name CityView
extends Node3D
## Renders the CitySim grid in 3D: Kenney roads picked by neighbor mask, zone lots and
## density-based buildings, Blender service models, fires and disaster VFX, data overlays,
## autonomous cars and pedestrians, AI mayor avatars, and GMI speech bubbles.

signal tile_clicked(x: int, y: int)
signal tile_hovered(x: int, y: int)
signal resident_clicked(id: String)
## Tile i's holder was (re)built; holder is the Node3D under Tiles that owns all of its nodes.
## Fires for every holder, including the full build inside setup().
signal tile_built(i: int, holder: Node3D)
## Tile i lost its holder and nothing replaced it (cleared to empty land or unburnt woods).
signal tile_cleared(i: int)
## setup() finished: every tile, CityLife and the avatars exist again.
signal world_rebuilt()
## fp_mode changed value (set_fp_mode with a different value). Not emitted by the boot-time field set.
signal fp_mode_changed(on: bool)

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const STREET := preload("res://scripts/fp/street/street_dressing.gd")
const M := "res://models/"
const B := "res://models/blender/"

const ROAD_STRAIGHT := M + "road-straight.glb"
const ROAD_LIGHTS := M + "road-straight-lightposts.glb"
const ROAD_CORNER := M + "road-corner.glb"
const ROAD_SPLIT := M + "road-split.glb"
const ROAD_CROSS := M + "road-intersection.glb"

const ZONE_MODELS := {
	D.ZONE_R: [[], [M + "building-small-a.glb", M + "building-small-d.glb"], [M + "building-small-b.glb", M + "building-small-c.glb"], [B + "apartment_tower.glb", B + "office.glb"]],
	D.ZONE_C: [[], [B + "media_studio.glb", M + "building-garage.glb"], [B + "exchange_hub.glb", B + "media_studio.glb"], [B + "landmark_compute_exchange.glb", B + "venture_tower.glb"]],
	D.ZONE_I: [[], [B + "garage.glb", B + "logistics_depot.glb"], [B + "logistics_depot.glb", B + "factory.glb"], [B + "factory.glb", B + "data_center.glb"]],
}
const SERVICE_MODELS := {
	D.COAL: B + "coal_plant.glb", D.SOLAR: B + "solar_array.glb", D.PUMP: B + "water_tower.glb",
	D.SEWAGE: B + "landmark_sewage_plant.glb", D.POLICE: B + "police_station.glb", D.FIRE: B + "fire_station.glb",
	D.HOSPITAL: B + "hospital.glb", D.SCHOOL: B + "school.glb", D.PARK: B + "park.glb", D.HALL: B + "landmark_council_dome.glb",
}
const CAR_MODELS := [M + "cars/sedan.glb", M + "cars/taxi.glb", M + "cars/van.glb", M + "cars/suv.glb", M + "cars/hatchback-sports.glb", M + "cars/police.glb"]
## New service buildings: first existing path wins, so older Blender assets stand in until the v3 models exist.
const NEW_SERVICE_MODELS := {
	D.WIND: ["buildings/wind_farm.glb", "blender/solar_array.glb"],
	D.STADIUM: ["buildings/stadium.glb", "blender/landmark_council_dome.glb"],
	D.TRAIN: ["buildings/train_station.glb", "blender/transit_plaza.glb"],
	D.UNIVERSITY: ["buildings/university.glb", "blender/school.glb"],
	D.LANDFILL: ["buildings/landfill.glb", "blender/logistics_depot.glb"],
	D.AIRPORT: ["buildings/airport.glb", "blender/landmark_substation.glb"],
}
## Realistic assets (Blender + Poly Haven PBR). Each falls back to the older models above when missing.
const R := "res://models/real/"
const TEX := "res://textures/real/"
const REAL_SCALE := WS.REAL_SCALE
const REAL_ROADS := {"straight": R + "roads/road_straight.glb", "lights": R + "roads/road_straight_lights.glb", "corner": R + "roads/road_corner.glb", "tee": R + "roads/road_tee.glb", "cross": R + "roads/road_cross.glb", "end": R + "roads/road_end.glb", "bridge": R + "roads/road_bridge.glb"}
const LEAF_TEXTURE := R + "buildings/hospital_leafcluster_round.png"
const TREE_PROPS := ["tree_oak", "tree_round", "tree_birch", "tree_poplar", "tree_conifer"]
## Trees are batched in square chunks so far chunks can switch to low-poly stand-ins and a
## cleared forest only rebuilds its own chunk. TREE_RING tiles of woods surround the world.
## Orbit: one 48-tile chunk carries both layers. On foot: 8-tile chunks carry full trees to
## TREE_NEAR_FP, then one merged stand-in mesh (a single draw per chunk) to TREE_FAR_FP, where the
## depth fog takes over. Both layers of a chunk measure from one centre, so they are exact
## complements: no gap and no double tree at the switch.
const TREE_CHUNK := 48
const TREE_RING := 12
const TREE_NEAR := 120.0
const TREE_CHUNK_FP := 8
const TREE_NEAR_FP := 12.0
const TREE_FAR_FP := 50.0
## Orbit C/I pad height (the FP pad, when a fallback model needs one, sits at WS.PAD_TOP).
const ORBIT_PAD_Y := 0.006
## Rebuild queue (FP only): frame budget, how close a tile in view must be to wait until the
## player looks away, and the longest it may wait.
const REBUILD_DEFER_DIST := 1.5
const REBUILD_DEFER_MAX_S := 5.0
## Ground: merged land quads per GROUND_CHUNK x GROUND_CHUNK tiles (water tiles excluded), out to
## GROUND_MARGIN tiles past the world edge. Water tiles get a riverbed whose banks slope from the
## ground down to WS.RIVERBED_Y over BANK_W.
const GROUND_CHUNK := 64
const GROUND_MARGIN := 30
const BANK_W := 0.1
const GROUND_SHADER := "res://shaders/ground_detail.gdshader"
const WINDOW_SHADER := "res://shaders/window_fp.gdshader"
const ROAD_SHADER := "res://shaders/road_fp.gdshader"
## Road-surface materials that darken and turn glossy in the rain (by resource-name prefix).
const WET_PREFIXES := ["Asphalt", "Sidewalk", "Curb", "Paint_White", "Paint_Yellow", "Concrete_Floor", "Court", "Track", "Turf"]
## Walls, roofs and trim that rain darkens without making them glossy.
const DAMP_PREFIXES := ["Brick", "Concrete", "Stone", "Plaster", "Roof", "Trim_Stone", "Wood"]
## Window glass tints: warm homes, cool offices, a dimmer warm, and mostly dark rooms.
const WINDOW_TINTS := [Color(1.0, 0.76, 0.46), Color(0.84, 0.91, 1.0), Color(1.0, 0.86, 0.62), Color(1.0, 0.70, 0.40)]
const WINDOW_GLOW := [3.4, 2.8, 1.9, 0.3]
## Wind turbine rotors face the wind along their local +Z, so they spin about that axis.
const ROTOR_AXIS := Vector3(0, 0, 1)
const R_PROPS := ["tree", "tree", "bench", "hydrant", "planter", "tree"]
const C_PROPS := ["lamp", "bench", "trash_bin", "planter", "lamp", "billboard"]
const I_PROPS := ["hydrant", "trash_bin", "lamp"]
const ZONE_COLORS := {D.ZONE_R: Color(0.30, 0.85, 0.42), D.ZONE_C: Color(0.30, 0.62, 1.0), D.ZONE_I: Color(1.0, 0.78, 0.25)}
const SHIRTS := [Color(0.95, 0.35, 0.30), Color(0.30, 0.55, 0.95), Color(0.35, 0.80, 0.45), Color(0.98, 0.80, 0.25), Color(0.70, 0.45, 0.90), Color(0.95, 0.55, 0.25), Color(0.40, 0.85, 0.85)]

var sim: CitySim
var camera: Camera3D
var overlay_mode: String = "none"

var _scenes: Dictionary = {}
var _tuned: Dictionary = {}
const MATTE_PREFIXES := ["Roof", "Brick", "Concrete", "Plaster", "Stone", "Trim_Stone", "Sidewalk", "Curb", "Asphalt", "Dirt", "Grass", "Gravel", "Rock", "Turf", "Wood", "Deck", "Siding", "Court", "Track", "Coal", "Garbage"]
const SHEET_METAL_PREFIXES := ["Metal_Corrugated", "Metal_Cladding", "Metal_Plate", "Metal_Rusty", "Shutter", "Container"]
var _tile_nodes: Dictionary = {}
var _prev_kind := PackedInt32Array()
var _prev_level := PackedInt32Array()
var _tiles_root: Node3D
var _fx_root: Node3D
var _cars_root: Node3D
var _peds_root: Node3D
var _labels_root: Node3D
var _overlay_mm: MultiMeshInstance3D
var _power_icons: MultiMeshInstance3D
var _water_icons: MultiMeshInstance3D
var _cursor: MeshInstance3D
var _cars: Array[Dictionary] = []
var _peds: Array[Dictionary] = []
var _bubbles: Array[Dictionary] = []
var _avatars: Array[Dictionary] = []
var _event_nodes: Dictionary = {}
var _time: float = 0.0
var _status_timer: float = 0.0
var _press_pos: Vector2 = Vector2.ZERO
var _pressed: bool = false
var _shake: float = 0.0
var _mats: Dictionary = {}
var _catalogs: Dictionary = {}
var _spinners: Array = []
var _blinkers: Array[Dictionary] = []
var bus_stops: Dictionary = {}
var life: CityLife
var avatars: ResidentAvatars
## 0 at noon, 1 at midnight; set by SkyDirector.
var night: float = 0.0
var _window_mats: Array[StandardMaterial3D] = []
## On foot every window shares one shader that varies room by room in world space.
var _window_fp_mat: ShaderMaterial
var _lamp_mat: StandardMaterial3D
var _water_mat: ShaderMaterial
var _tex_mats: Dictionary = {}
var _real_roads: bool = false
## Tree models, one Array of mesh parts per kit, plus a low-poly stand-in for distant chunks.
var _tree_kits: Array = []
var _far_tree_parts: Array = []
var _trees_root: Node3D
## Tree chunk (Vector2i) -> its MultiMeshInstance3D layers; dirty chunks rebuild next frame.
var _tree_chunks: Dictionary = {}
var _dirty_tree_chunks: Dictionary = {}
var _pool_mat: StandardMaterial3D
var _territory_root: Node3D
var kit: ConstructionKit
var _site_timer: float = 0.0
var _bounds_cache: Dictionary = {}
## True while setup() runs (from its first line until just before world_rebuilt.emit()). tile_built
## listeners that do per-tile work skip it while in_setup and do one full pass on world_rebuilt.
var in_setup: bool = false
## Street-level presentation: hides builder aids and the AI presentation layer, stops ambient
## traffic, picking and camera shake. Persists across setup().
var fp_mode: bool = false
## Street names and the lot frontage rule, rebuilt by setup().
var directory: CityDirectory
## The player's position on foot, set every frame by the streetscape feature. The FP rebuild queue
## builds nearest-first to it; close-range FX (dust puffs) test against it.
var priority_point: Vector3 = Vector3.ZERO
## FP rebuild budget per frame in milliseconds, tile_built emissions included.
var rebuild_budget_ms: float = 3.0
## Worst microseconds per _process section since reset_section_stats() (fp_bench's hitch rows).
var section_us_max: Dictionary = {}
## Any object with light_pole(i: int, corner: int) -> Node3D (E's traffic feature). Cross tiles then
## mount their street-name blades on its NE pole instead of a G1 pole. Set by the streetscape feature.
var light_pole_source: Object = null
## Visibility multiplier for the props, decals and multimeshes G1 ranges itself (G2's vis_mult).
var vis_mult: float = 1.0
## 0 dry .. 1 soaked; set by the streetscape weather through set_wetness().
var wetness: float = 0.0
## FP rebuild queue: tile index -> seconds it has waited deferred (near and in view).
var _queue: Dictionary = {}
## Scene paths being loaded on a thread for the queue (path -> true).
var _warming: Dictionary = {}
var _flicker_lights: Array[OmniLight3D] = []
var _street: STREET
var _ground_chunks: Array[MeshInstance3D] = []
var _ground_fp_mat: ShaderMaterial
var _lot_mat: ShaderMaterial
var _lawn_mat: ShaderMaterial
var _bank_mat: ShaderMaterial
var _apron_mat: StandardMaterial3D
var _road_fp_mat: ShaderMaterial
var _water_node: MeshInstance3D
var _bed_node: MeshInstance3D
## Shared road-surface materials -> [dry albedo, roughness, metallic_specular] for set_wetness().
var _wet_mats: Dictionary = {}


func setup(p_sim: CitySim, p_camera: Camera3D) -> void:
	in_setup = true
	sim = p_sim
	camera = p_camera
	for c in get_children():
		c.queue_free()
	_tile_nodes.clear()
	_event_nodes.clear()
	_cars.clear()
	_peds.clear()
	_bubbles.clear()
	_avatars.clear()
	_queue.clear()
	_flicker_lights.clear()
	_territory_root = null
	directory = CityDirectory.new()
	directory.setup(sim)
	_street = STREET.new(self)
	_tiles_root = _mk_root("Tiles")
	_fx_root = _mk_root("Effects")
	_cars_root = _mk_root("Cars")
	_peds_root = _mk_root("Pedestrians")
	_labels_root = _mk_root("Labels")
	kit = ConstructionKit.new(self)
	_real_roads = true
	for key: String in ["straight", "corner", "tee", "cross"]:
		_real_roads = _real_roads and ResourceLoader.exists(REAL_ROADS[key])
	_build_ground()
	_build_trees()
	_build_district_borders()
	_overlay_mm = _make_overlay_multimesh()
	_overlay_mm.visible = false
	add_child(_overlay_mm)
	_power_icons = _make_icon_multimesh(Color(1.0, 0.25, 0.2))
	_water_icons = _make_icon_multimesh(Color(0.25, 0.6, 1.0))
	_build_cursor()
	_build_avatars()
	_spinners.clear()
	_blinkers.clear()
	bus_stops.clear()
	life = CityLife.new()
	life.name = "CityLife"
	add_child(life)
	_prev_kind = PackedInt32Array()
	_prev_kind.resize(D.W * D.H)
	_prev_kind.fill(-1)
	_prev_level = PackedInt32Array()
	_prev_level.resize(D.W * D.H)
	_prev_level.fill(-1)
	rebuild_all(false)
	_refresh_trees()
	life.setup(sim, self)
	avatars = null
	if sim.people != null:
		avatars = ResidentAvatars.new()
		avatars.name = "Residents"
		add_child(avatars)
		avatars.setup(sim, sim.people, camera)
	if not sim.tiles_changed.is_connected(_on_tiles_changed):
		sim.tiles_changed.connect(_on_tiles_changed)
		sim.event_started.connect(func(ev: Dictionary) -> void:
			_sync_events()
			if str(ev["type"]) == "earthquake" and not fp_mode:
				_shake = 1.2
		)
		sim.event_ended.connect(func(_ev: Dictionary) -> void: _sync_events())
		sim.territory_changed.connect(_rebuild_territory)
	_apply_fp_visibility()
	in_setup = false
	world_rebuilt.emit()


## Switches between the orbit and the street-level presentation. On a real change it also rebuilds
## the mode-specific geometry synchronously (tree chunks, every tile: lots, pads, furniture, FX),
## bypassing the rebuild queue, then emits world_rebuilt and fp_mode_changed. Setting the same value
## again does nothing; the boot path sets the field before the first setup() instead.
func set_fp_mode(on: bool) -> void:
	var changed := on != fp_mode
	fp_mode = on
	if changed and sim != null and _tiles_root != null:
		_queue.clear()
		if _trees_root != null:
			_trees_root.free()
		for id: int in _event_nodes.keys():
			(_event_nodes[id] as Node3D).queue_free()
		_event_nodes.clear()
		_apply_ground_mode()
		_build_trees()
		_refresh_trees()
		rebuild_all(false)
		_apply_night()
	_apply_fp_visibility()
	if changed:
		if sim != null and _tiles_root != null:
			world_rebuilt.emit()
		fp_mode_changed.emit(on)


## Shows or hides the orbit-only layers for fp_mode (S0 §15.1): labels, territory, overlays, icons,
## cursor, mayor bots, event labels and the ambient Kenney cars and pedestrians.
func _apply_fp_visibility() -> void:
	if _labels_root == null:
		return
	var orbit := not fp_mode
	_shake = 0.0
	if avatars != null:
		avatars.fp_hidden = fp_mode
	_labels_root.visible = orbit
	if _territory_root != null:
		_territory_root.visible = orbit
	_power_icons.visible = orbit
	_water_icons.visible = orbit
	if _cursor != null and fp_mode:
		_cursor.visible = false
	for av: Dictionary in _avatars:
		(av["root"] as Node3D).visible = orbit
	for id: int in _event_nodes.keys():
		for c in (_event_nodes[id] as Node3D).get_children():
			if c.has_meta("orbit_only"):
				(c as Node3D).visible = orbit
	_cars_root.visible = orbit
	_peds_root.visible = orbit
	if fp_mode:
		for list: Array in [_cars, _peds]:
			for a: Dictionary in list:
				(a["node"] as Node3D).queue_free()
			list.clear()
		if overlay_mode != "none":
			set_overlay("none")
	elif not in_setup:
		_refresh_status()


func _mk_root(n: String) -> Node3D:
	var r := Node3D.new()
	r.name = n
	add_child(r)
	return r


func _scene(path: String) -> PackedScene:
	if not _scenes.has(path):
		var ps: PackedScene = null
		if _warming.has(path):
			# A threaded warm-up of this scene is running: wait for it instead of loading it twice.
			_warming.erase(path)
			ps = ResourceLoader.load_threaded_get(path) as PackedScene
		elif ResourceLoader.exists(path):
			ps = load(path)
		if ps != null:
			_tune_materials(ps)
		_scenes[path] = ps
	return _scenes[path]


## The realistic GLBs pack ARM maps whose blue (metal) channel the importer reads as fully
## metallic, so roofs, brick and concrete mirrored the sky. Glass and bare metal were also
## mirror-smooth. Fix each shared material once, by name, when its scene first loads.
func _tune_materials(ps: PackedScene) -> void:
	var root := ps.instantiate()
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (n as MeshInstance3D).mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var m := mesh.surface_get_material(s) as BaseMaterial3D
			if m == null or _tuned.has(m.get_instance_id()):
				continue
			_tuned[m.get_instance_id()] = true
			_tune_material(m)
			for p: String in WET_PREFIXES + DAMP_PREFIXES:
				if m.resource_name.begins_with(p):
					_wet_mats[m] = [m.albedo_color, m.roughness, m.metallic_specular, p in DAMP_PREFIXES]
					_wet_material(m, wetness)
					break
	root.free()


static func _tune_material(m: BaseMaterial3D) -> void:
	var nm := m.resource_name
	for p: String in MATTE_PREFIXES:
		if nm.begins_with(p):
			m.metallic = 0.0
			m.metallic_texture = null
			m.metallic_specular = 0.3
			# Their scanned roughness still reads as glossy from above; flat matte suits them.
			if nm.begins_with("Roof") or nm.begins_with("Gravel") or nm.begins_with("Asphalt") or nm.begins_with("Sidewalk"):
				m.roughness_texture = null
				m.roughness = 0.92
			return
	for p: String in SHEET_METAL_PREFIXES:
		if nm.begins_with(p):
			m.metallic = 0.35
			m.roughness_texture = null
			m.roughness = 0.72
			return
	if nm == "Solar_Panel":
		m.metallic = 0.3
	elif nm.begins_with("Glass") or nm.begins_with("WindowLit"):
		m.metallic = minf(m.metallic, 0.3)
		m.roughness = maxf(m.roughness, 0.14)
	elif nm == "Chrome":
		m.roughness = maxf(m.roughness, 0.25)
	elif nm in ["Metal_Galv", "Frame_Alu", "Metal_Dark"]:
		m.roughness = maxf(m.roughness, 0.5)


func _inst(path: String) -> Node3D:
	var s := _scene(path)
	return s.instantiate() as Node3D if s != null else null


func _mat(key: String, col: Color, emissive: float = 0.0, alpha: float = 1.0) -> StandardMaterial3D:
	var k := "%s_%s_%.2f_%.2f" % [key, col.to_html(), emissive, alpha]
	if _mats.has(k):
		return _mats[k]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emissive
	m.roughness = 0.9
	_mats[k] = m
	return m


# ------------------------------------------------------------------ static scenery

## The ground at WS.GROUND_Y as merged land quads in chunks (no ground under water), the riverbed with
## sloped banks under every water tile, and the water surface at WS.WATER_Y.
func _build_ground() -> void:
	_ground_chunks.clear()
	var lo := Vector2i(D.X0 - GROUND_MARGIN, D.Y0 - GROUND_MARGIN)
	var hi := Vector2i(D.X0 + D.W + GROUND_MARGIN, D.Y0 + D.H + GROUND_MARGIN)
	for cy in range(lo.y, hi.y, GROUND_CHUNK):
		for cx in range(lo.x, hi.x, GROUND_CHUNK):
			var mesh := _ground_chunk_mesh(cx, cy, mini(cx + GROUND_CHUNK, hi.x), mini(cy + GROUND_CHUNK, hi.y))
			if mesh == null:
				continue
			var g := MeshInstance3D.new()
			g.name = "Ground"
			g.mesh = mesh
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(g)
			_ground_chunks.append(g)
	var is_water := func(i: int) -> bool: return sim.terrain[i] == D.WATER
	_bed_node = MeshInstance3D.new()
	_bed_node.name = "RiverBed"
	_bed_node.mesh = _river_bed_mesh()
	_bed_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bed_node)
	_water_node = MeshInstance3D.new()
	_water_node.name = "Water"
	_water_node.mesh = _tiles_mesh(is_water, WS.WATER_Y, 1.0)
	_water_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if ResourceLoader.exists("res://shaders/water.gdshader"):
		_water_mat = ShaderMaterial.new()
		_water_mat.shader = load("res://shaders/water.gdshader")
		if ResourceLoader.exists(TEX + "water_normal.png"):
			_water_mat.set_shader_parameter("normal_tex", load(TEX + "water_normal.png"))
		_water_mat.set_shader_parameter("night", night)
		_water_node.material_override = _water_mat
	else:
		_water_node.material_override = _mat("water_glow", Color(0.2, 0.45, 0.6), 0.0, 0.8)
	add_child(_water_node)
	_apply_ground_mode()


func _is_water_at(x: int, y: int) -> bool:
	return D.in_bounds(x, y) and sim.terrain[D.idx(x, y)] == D.WATER


## Land quads of tiles [x0, x1) x [y0, y1) at GROUND_Y, one quad per run of land tiles in a row; UV
## is world xz (tangents follow +x) for the detail shader. Null when the chunk is all water.
func _ground_chunk_mesh(x0: int, y0: int, x1: int, y1: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for y in range(y0, y1):
		var x := x0
		while x < x1:
			if _is_water_at(x, y):
				x += 1
				continue
			var xe := x
			while xe + 1 < x1 and not _is_water_at(xe + 1, y):
				xe += 1
			var a := Vector3(x - 0.5, WS.GROUND_Y, y - 0.5)
			var b := Vector3(xe + 0.5, WS.GROUND_Y, y - 0.5)
			var c := Vector3(xe + 0.5, WS.GROUND_Y, y + 0.5)
			var d := Vector3(x - 0.5, WS.GROUND_Y, y + 0.5)
			for v: Vector3 in [a, b, c, a, c, d]:
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(v.x, v.z))
				st.add_vertex(v)
			any = true
			x = xe + 1
	if not any:
		return null
	st.generate_tangents()
	return st.commit()


## Riverbed under the water tiles at RIVERBED_Y, rising to GROUND_Y over BANK_W at every edge or
## corner that touches land, so the water sits below its banks instead of level with the lots.
func _river_bed_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var g := [0.0, BANK_W, 1.0 - BANK_W, 1.0]
	var any := false
	for i in range(D.W * D.H):
		if sim.terrain[i] != D.WATER:
			continue
		any = true
		var x := D.tx(i)
		var y := D.ty(i)
		var land := [
			not _is_water_at(x, y - 1), not _is_water_at(x + 1, y), not _is_water_at(x, y + 1), not _is_water_at(x - 1, y),
			not _is_water_at(x - 1, y - 1), not _is_water_at(x + 1, y - 1), not _is_water_at(x + 1, y + 1), not _is_water_at(x - 1, y + 1),
		]
		var pts := []
		for gy: float in g:
			var row := []
			for gx: float in g:
				var dist := 2.0
				if land[0]:
					dist = minf(dist, gy)
				if land[1]:
					dist = minf(dist, 1.0 - gx)
				if land[2]:
					dist = minf(dist, 1.0 - gy)
				if land[3]:
					dist = minf(dist, gx)
				var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
				for k in range(4):
					if land[4 + k]:
						dist = minf(dist, Vector2(gx, gy).distance_to(corners[k]))
				var h := lerpf(WS.GROUND_Y, WS.RIVERBED_Y, smoothstep(0.0, BANK_W, dist))
				row.append(Vector3(x - 0.5 + gx, h, y - 0.5 + gy))
			pts.append(row)
		for r in range(3):
			for c in range(3):
				var a: Vector3 = pts[r][c]
				var b: Vector3 = pts[r][c + 1]
				var cc: Vector3 = pts[r + 1][c + 1]
				var d: Vector3 = pts[r + 1][c]
				for v: Vector3 in [a, b, cc, a, cc, d]:
					st.set_uv(Vector2(v.x, v.z))
					st.add_vertex(v)
	if not any:
		return ArrayMesh.new()
	st.index()
	st.generate_normals()
	return st.commit()


## Ground and water materials for the current mode: the metric detail shader with depth-faded water
## on foot, the old large-scale grass and plain water in orbit.
func _apply_ground_mode() -> void:
	var gm: Material = _ground_material()
	for g in _ground_chunks:
		if is_instance_valid(g):
			g.material_override = gm
	if _bed_node != null:
		_bed_node.material_override = _bank_material() if fp_mode else _pbr("dirt", Color(0.22, 0.2, 0.17), 0.6)
	if _water_mat != null:
		# On foot a darker, greener city river; the sky's reflection supplies the blue.
		_water_mat.set_shader_parameter("deep_color", Color(0.03, 0.075, 0.075) if fp_mode else Color(0.10, 0.30, 0.38))
		_water_mat.set_shader_parameter("shallow_color", Color(0.09, 0.15, 0.13) if fp_mode else Color(0.22, 0.48, 0.52))
		# Normal-map repeats: one per 8 m on foot; the depth read fades the shallows and foams the banks.
		_water_mat.set_shader_parameter("tiling", 1.0 / (8.0 * WS.M) if fp_mode else 0.35)
		_water_mat.set_shader_parameter("speed", 0.05 if fp_mode else 0.03)
		_water_mat.set_shader_parameter("depth_fade", 0.045 if fp_mode else 0.0)
		_water_mat.set_shader_parameter("foam_width", 0.006)


func _ground_material() -> Material:
	if not fp_mode or not ResourceLoader.exists(GROUND_SHADER) or not ResourceLoader.exists(TEX + "grass_albedo.jpg"):
		var m := _pbr("grass", Color(0.36, 0.6, 0.3), 0.18, Color(1.12, 1.15, 1.0))
		m.normal_scale = 0.45
		return m
	if _ground_fp_mat == null:
		_ground_fp_mat = ShaderMaterial.new()
		_ground_fp_mat.shader = load(GROUND_SHADER)
		for key: String in ["grass_albedo", "grass_normal", "grass_rough", "dirt_albedo", "dirt_normal"]:
			var p := TEX + key + ".jpg"
			if ResourceLoader.exists(p):
				_ground_fp_mat.set_shader_parameter(key, load(p))
		_ground_fp_mat.set_shader_parameter("detail_scale", 1.0 / (3.0 * WS.M))
		_ground_fp_mat.set_shader_parameter("macro_scale", 1.0 / (40.0 * WS.M))
		_ground_fp_mat.set_shader_parameter("grass_tint", Color(1.0, 1.04, 0.96))
		_ground_fp_mat.set_shader_parameter("wetness", wetness)
	return _ground_fp_mat


## River banks and bed on foot: the ground shader turned mostly to wet earth with grassy tufts.
func _bank_material() -> Material:
	var base := _ground_material()
	if not (base is ShaderMaterial):
		return _pbr("dirt", Color(0.22, 0.2, 0.17), 1.0 / (3.0 * WS.M))
	if _bank_mat == null:
		_bank_mat = (base as ShaderMaterial).duplicate() as ShaderMaterial
		_bank_mat.set_shader_parameter("dirt", 0.8)
		_bank_mat.set_shader_parameter("wetness", maxf(wetness, 0.35))
	return _bank_mat


## Ground for a vacant lot on foot: the detail shader turned to patchy earth that fades back to grass
## at the lot's edges.
func lot_ground_material() -> Material:
	var base := _ground_material()
	if not (base is ShaderMaterial):
		return _pbr("dirt", Color(0.35, 0.3, 0.25), 1.0 / (3.0 * WS.M))
	if _lot_mat == null:
		_lot_mat = (base as ShaderMaterial).duplicate() as ShaderMaterial
		_lot_mat.set_shader_parameter("dirt", 0.62)
		_lot_mat.set_shader_parameter("lot_edge", 1.0)
		_lot_mat.set_shader_parameter("wetness", wetness)
	return _lot_mat


## Lawns and park grass of the building models on foot (their flat "Grass" surfaces): the street's
## metric grass, a little lusher and with fewer worn patches. Null without the ground shader.
func lawn_material() -> ShaderMaterial:
	var base := _ground_material()
	if not (base is ShaderMaterial):
		return null
	if _lawn_mat == null:
		_lawn_mat = (base as ShaderMaterial).duplicate() as ShaderMaterial
		_lawn_mat.set_shader_parameter("grass_tint", Color(0.96, 1.08, 0.92))
		_lawn_mat.set_shader_parameter("wetness", wetness)
	return _lawn_mat


## Paving for the aprons between lots and road sidewalks: the road's own sidewalk material, world
## tiled at the road's density (one repeat per 3 m).
func apron_material() -> Material:
	if _apron_mat == null:
		var src: BaseMaterial3D = null
		var road := _inst(_road_path("straight"))
		if road != null:
			for n in road.find_children("*", "MeshInstance3D", true, false):
				var mesh := (n as MeshInstance3D).mesh
				for s in range(mesh.get_surface_count()):
					var m := mesh.surface_get_material(s) as BaseMaterial3D
					if m != null and m.resource_name == "Sidewalk":
						src = m
			road.free()
		if src != null:
			_apron_mat = src.duplicate() as StandardMaterial3D
			_apron_mat.uv1_triplanar = true
			_apron_mat.uv1_world_triplanar = true
			_apron_mat.uv1_scale = Vector3.ONE / (3.0 * WS.M)
			_wet_mats[_apron_mat] = [_apron_mat.albedo_color, _apron_mat.roughness, _apron_mat.metallic_specular]
			_wet_material(_apron_mat, wetness)
		else:
			_apron_mat = _pbr("sidewalk", Color(0.6, 0.6, 0.58), 1.0 / (3.0 * WS.M))
	return _apron_mat


## Carriageway asphalt on foot (shaders/road_fp.gdshader): world-mapped, broken-up asphalt with lane
## wear; road holders set its `lane_axis` instance parameter. Null when the shader or textures are
## missing (the road models keep their own asphalt).
func road_fp_material() -> ShaderMaterial:
	if _road_fp_mat == null and ResourceLoader.exists(ROAD_SHADER) and ResourceLoader.exists(TEX + "asphalt_albedo.jpg"):
		_road_fp_mat = ShaderMaterial.new()
		_road_fp_mat.shader = load(ROAD_SHADER)
		for pair: Array in [["albedo_tex", "asphalt_albedo.jpg"], ["normal_tex", "asphalt_normal.jpg"], ["rough_tex", "asphalt_rough.jpg"], ["noise_tex", "decals/noise_fbm.png"]]:
			if ResourceLoader.exists(TEX + str(pair[1])):
				_road_fp_mat.set_shader_parameter(str(pair[0]), load(TEX + str(pair[1])))
		_road_fp_mat.set_shader_parameter("metre", WS.M)
		_road_fp_mat.set_shader_parameter("lane_offset", WS.LANE_OFFSET)
		_road_fp_mat.set_shader_parameter("half_width", WS.ROAD_HALF)
		_road_fp_mat.set_shader_parameter("wetness", wetness)
	return _road_fp_mat


## Sets light_pole_source (E's traffic feature, or null) and, on a change while on foot, re-hangs
## the street-name blades of the cross tiles already built (they were built before the source).
func set_light_pole_source(src: Object) -> void:
	if src == light_pole_source:
		return
	light_pole_source = src
	if fp_mode and _street != null:
		_street.remount_cross_signs()


## Wet streets: road and sidewalk materials darken and turn glossy, the ground shaders and the water
## follow, and puddles appear by the curbs. w is 0 (dry) .. 1 (soaked).
func set_wetness(w: float) -> void:
	w = clampf(w, 0.0, 1.0)
	if absf(w - wetness) < 0.002 and w != 0.0:
		return
	wetness = w
	for m: BaseMaterial3D in _wet_mats.keys():
		if is_instance_valid(m):
			_wet_material(m, w)
	for sm: ShaderMaterial in [_ground_fp_mat, _lot_mat, _road_fp_mat, _lawn_mat]:
		if sm != null:
			sm.set_shader_parameter("wetness", w)
	if _bank_mat != null:
		_bank_mat.set_shader_parameter("wetness", maxf(w, 0.35))
	if _street != null:
		_street.set_wetness(w)


## Rain falling now (0 none .. 1 full): rings on the river.
func set_rain(r: float) -> void:
	if _water_mat != null:
		_water_mat.set_shader_parameter("rain", clampf(r, 0.0, 1.0) if fp_mode else 0.0)


func _wet_material(m: BaseMaterial3D, w: float) -> void:
	var dry: Array = _wet_mats[m]
	var c: Color = dry[0]
	var damp := dry.size() > 3 and bool(dry[3])
	var k := lerpf(1.0, 0.78 if damp else 0.62, w)
	m.albedo_color = Color(c.r * k, c.g * k, c.b * k, c.a)
	m.roughness = lerpf(float(dry[1]), float(dry[1]) * 0.8 if damp else 0.16, w)
	m.metallic_specular = lerpf(float(dry[2]), 0.4 if damp else 0.65, w)


## One merged quad mesh over every tile the predicate accepts, so water costs a single draw call.
func _tiles_mesh(pred: Callable, y: float, size: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	var hs := size * 0.5
	var any := false
	for i in range(D.W * D.H):
		if not bool(pred.call(i)):
			continue
		any = true
		var c := Vector3(D.tx(i), y, D.ty(i))
		var a := c + Vector3(-hs, 0, -hs)
		var b := c + Vector3(hs, 0, -hs)
		var d := c + Vector3(hs, 0, hs)
		var e := c + Vector3(-hs, 0, hs)
		for v: Vector3 in [a, b, d, a, d, e]:
			st.set_uv(Vector2(v.x, v.z))
			st.add_vertex(v)
	if not any:
		return ArrayMesh.new()
	return st.commit()


## One flat quad per tile rect (rects in tile coordinates, edges on tile borders).
func _rects_mesh(rects: Array[Rect2i], y: float) -> ArrayMesh:
	if rects.is_empty():
		return ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for r in rects:
		var a := Vector3(r.position.x - 0.5, y, r.position.y - 0.5)
		var b := Vector3(r.end.x - 0.5, y, r.position.y - 0.5)
		var d := Vector3(r.end.x - 0.5, y, r.end.y - 0.5)
		var c := Vector3(r.position.x - 0.5, y, r.end.y - 0.5)
		for v: Vector3 in [a, b, d, a, d, c]:
			st.set_uv(Vector2(v.x, v.z))
			st.add_vertex(v)
	return st.commit()


## Poly Haven ground material with world-space tiling; falls back to a flat colour.
func _pbr(name: String, fallback: Color, scale: float, tint: Color = Color.WHITE) -> StandardMaterial3D:
	var key := "%s_%.2f_%s" % [name, scale, tint.to_html()]
	if _tex_mats.has(key):
		return _tex_mats[key]
	var m := StandardMaterial3D.new()
	var albedo := TEX + name + "_albedo.jpg"
	if ResourceLoader.exists(albedo):
		m.albedo_texture = load(albedo)
		m.albedo_color = tint
		if ResourceLoader.exists(TEX + name + "_normal.jpg"):
			m.normal_enabled = true
			m.normal_texture = load(TEX + name + "_normal.jpg")
		if ResourceLoader.exists(TEX + name + "_rough.jpg"):
			m.roughness_texture = load(TEX + name + "_rough.jpg")
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE * scale
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	else:
		m.albedo_color = fallback
	m.roughness = 1.0
	_tex_mats[key] = m
	return m

## Data-view columns: one translucent box per tile, height scaled by the overlay value.
func _make_overlay_multimesh() -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(0.94, 1.0, 0.94)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.6
	mat.emission_enabled = true
	mat.emission = Color(0.12, 0.12, 0.12)
	box.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = D.W * D.H
	for i in range(D.W * D.H):
		mm.set_instance_transform(i, _column(i, 0.0))
		mm.set_instance_color(i, Color(0, 0, 0, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


func _column(i: int, h: float) -> Transform3D:
	var hh := maxf(h, 0.001)
	return Transform3D(Basis().scaled(Vector3(1.0, hh, 1.0)), Vector3(D.tx(i), 0.06 + hh * 0.5, D.ty(i)))


func _make_icon_multimesh(col: Color) -> MultiMeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.09
	mesh.height = 0.18
	mesh.radial_segments = 4
	mesh.rings = 2
	mesh.material = _mat("icon", col, 3.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = D.W * D.H
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)
	return mmi


## Trees are city-wide multimeshes, one per tree-model part, covering the wilderness ring around
## the map and every forest tile. Real Blender tree props are preferred over procedural crowns.
func _build_trees() -> void:
	_tree_chunks.clear()
	_dirty_tree_chunks.clear()
	_trees_root = _mk_root("Trees")
	var kits: Array = []
	for tree_name in TREE_PROPS:
		var path := R + "props/%s.glb" % tree_name
		if not ResourceLoader.exists(path):
			continue
		var inst := _inst(path)
		if inst == null:
			continue
		var parts: Array = []
		_collect_meshes(inst, Transform3D(), parts)
		inst.free()
		if not parts.is_empty():
			kits.append(_street.fp_tree_parts(parts) if fp_mode else parts)
	if kits.is_empty():
		kits.append(_procedural_tree_parts())
	_tree_kits = kits
	_far_tree_parts = _fp_far_tree_parts() if fp_mode else _low_poly_tree_parts()


func _collect_meshes(n: Node, xf: Transform3D, out: Array) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mi := n as MeshInstance3D
		out.append({"mesh": mi.mesh, "xform": t, "mat": mi.material_override})
	for c in n.get_children():
		_collect_meshes(c, t, out)


func _procedural_tree_parts() -> Array:
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.018
	trunk.bottom_radius = 0.03
	trunk.height = 0.26
	trunk.radial_segments = 6
	trunk.rings = 1
	trunk.material = _mat("bark", Color(0.27, 0.2, 0.14))
	var crown := SphereMesh.new()
	crown.radius = 0.15
	crown.height = 0.3
	crown.radial_segments = 10
	crown.rings = 6
	crown.material = _mat("crown", Color(0.13, 0.24, 0.08))
	var shell := SphereMesh.new()
	shell.radius = 0.19
	shell.height = 0.36
	shell.radial_segments = 12
	shell.rings = 8
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = Color(0.22, 0.36, 0.13)
	leaf_mat.roughness = 0.9
	leaf_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if ResourceLoader.exists(LEAF_TEXTURE):
		leaf_mat.albedo_texture = load(LEAF_TEXTURE)
		leaf_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		leaf_mat.alpha_scissor_threshold = 0.45
		leaf_mat.uv1_triplanar = true
		leaf_mat.uv1_scale = Vector3.ONE * 3.0
	shell.material = leaf_mat
	return [
		{"mesh": trunk, "xform": Transform3D(Basis(), Vector3(0, 0.13, 0))},
		{"mesh": crown, "xform": Transform3D(Basis(), Vector3(0, 0.36, 0))},
		{"mesh": shell, "xform": Transform3D(Basis(), Vector3(0, 0.36, 0))},
	]


## Cheap trees for chunks far from the camera: a few-sided trunk and crown, no shadows.
func _low_poly_tree_parts() -> Array:
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.02
	trunk.bottom_radius = 0.03
	trunk.height = 0.26
	trunk.radial_segments = 5
	trunk.rings = 1
	trunk.material = _mat("bark", Color(0.27, 0.2, 0.14))
	var crown := SphereMesh.new()
	crown.radius = 0.19
	crown.height = 0.4
	crown.radial_segments = 7
	crown.rings = 4
	crown.material = _mat("far_crown", Color(0.17, 0.3, 0.11))
	return [
		{"mesh": trunk, "xform": Transform3D(Basis(), Vector3(0, 0.13, 0))},
		{"mesh": crown, "xform": Transform3D(Basis(), Vector3(0, 0.38, 0))},
	]


## Distant trees on foot (12-50 u): an impostor of three crossed leaf cards (6 triangles) with
## normals radiating from the crown, drawn by the foliage shader with a per-tree tint, over a
## crossed trunk card. Real trees cost thousands of triangles; at 6-27 px these read the same.
func _fp_far_tree_parts() -> Array:
	var leaf := R + "props/tree_round_leafcluster_round.png"
	var shader := "res://shaders/foliage.gdshader"
	if not ResourceLoader.exists(leaf) or not ResourceLoader.exists(shader):
		return _low_poly_tree_parts()
	var centre := Vector3(0, 0.27, 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(3):
		var d := Vector3(cos(float(k) * PI / 3.0), 0, sin(float(k) * PI / 3.0)) * 0.14
		_card(st, -d, d, 0.14, 0.4, centre)
	var crown := ShaderMaterial.new()
	crown.shader = load(shader)
	crown.set_shader_parameter("albedo_tex", load(leaf))
	crown.set_shader_parameter("tint", Color(0.78, 0.9, 0.7))
	crown.set_shader_parameter("up_bias", 0.25)
	crown.set_shader_parameter("wind", 0.0)
	# Three crossed cards: thin the most edge-on one gently, never all three.
	crown.set_shader_parameter("edge_lo", 0.0)
	crown.set_shader_parameter("edge_hi", 0.3)
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(2):
		var d2 := Vector3(cos(float(k) * PI * 0.5), 0, sin(float(k) * PI * 0.5)) * 0.012
		_card(st2, -d2, d2, 0.0, 0.2, Vector3.INF)
	var bark := StandardMaterial3D.new()
	bark.albedo_color = Color(0.22, 0.17, 0.12)
	bark.roughness = 0.95
	bark.cull_mode = BaseMaterial3D.CULL_DISABLED
	return [
		{"mesh": st.commit(), "xform": Transform3D(), "mat": crown, "tint": true},
		{"mesh": st2.commit(), "xform": Transform3D(), "mat": bark},
	]


## One vertical card from a to b (xz), y0..y1, UV 0..1; with a finite centre the normals radiate
## from it, else they face the card's own normal.
func _card(st: SurfaceTool, a: Vector3, b: Vector3, y0: float, y1: float, centre: Vector3) -> void:
	var p := [a + Vector3(0, y1, 0), b + Vector3(0, y1, 0), b + Vector3(0, y0, 0), a + Vector3(0, y0, 0)]
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var flat := (b - a).cross(Vector3.UP).normalized()
	for k: int in [0, 1, 2, 0, 2, 3]:
		var v: Vector3 = p[k]
		st.set_normal((v - centre).normalized() if centre.is_finite() else flat)
		st.set_uv(uv[k])
		st.add_vertex(v)


## Chunk key of tile (x, y) for a tree layer: z = 0 the orbit chunks, 1 the FP chunks.
func _tree_chunk_of(x: int, y: int, layer: int = 0) -> Vector3i:
	var size := _tree_chunk_size(layer)
	return Vector3i(floori(float(x - D.X0 + TREE_RING) / size), floori(float(y - D.Y0 + TREE_RING) / size), layer)


func _tree_chunk_size(layer: int) -> int:
	return TREE_CHUNK if layer == 0 else TREE_CHUNK_FP


## The chunk set in use: 48-tile chunks in orbit, 8-tile chunks on foot.
func _tree_layers() -> Array[int]:
	return [1] if fp_mode else [0]


## Marks the chunks holding tile (x, y) for a rebuild next frame.
func _dirty_trees_at(x: int, y: int) -> void:
	for layer in _tree_layers():
		_dirty_tree_chunks[_tree_chunk_of(x, y, layer)] = true


## Rebuilds every tree chunk: the forest tiles of the world plus a ring of woods beyond its edge.
func _refresh_trees() -> void:
	for layer in _tree_layers():
		var lo := _tree_chunk_of(D.X0 - TREE_RING, D.Y0 - TREE_RING, layer)
		var hi := _tree_chunk_of(D.X0 + D.W + TREE_RING - 1, D.Y0 + D.H + TREE_RING - 1, layer)
		for cy in range(lo.y, hi.y + 1):
			for cx in range(lo.x, hi.x + 1):
				_refresh_tree_chunk(Vector3i(cx, cy, layer))
	_dirty_tree_chunks.clear()


func _refresh_tree_chunk(c: Vector3i) -> void:
	var size := _tree_chunk_size(c.z)
	var by_kit: Array = []
	for _k in range(maxi(1, _tree_kits.size())):
		by_kit.append([])
	var x0 := D.X0 - TREE_RING + c.x * size
	var z0 := D.Y0 - TREE_RING + c.y * size
	for gx in range(x0, mini(x0 + size, D.X0 + D.W + TREE_RING)):
		for gz in range(z0, mini(z0 + size, D.Y0 + D.H + TREE_RING)):
			var inside := D.in_bounds(gx, gz)
			var h := absi(gx * 73856093 ^ gz * 19349663)
			var n := 0
			if inside:
				n = 4 if sim.kind[D.idx(gx, gz)] == D.FOREST else 0
			else:
				var ring := maxi(maxi(D.X0 - gx, gx - D.X0 - D.W + 1), maxi(D.Y0 - gz, gz - D.Y0 - D.H + 1))
				if ring > TREE_RING:
					continue
				n = 3 if ring <= 4 else (1 if h % 3 != 0 else 0)
			for t in range(n):
				var hh := (h >> (t * 4)) & 0xffff
				var ox := float(hh % 61) / 60.0 - 0.5
				var oz := float((hh >> 6) % 61) / 60.0 - 0.5
				var sc := 1.0 + float(hh % 7) * 0.1
				var yaw := Basis(Vector3.UP, float(hh % 13) / 13.0 * TAU).scaled(Vector3.ONE * sc)
				(by_kit[(hh >> 3) % by_kit.size()] as Array).append(Transform3D(yaw, Vector3(gx + ox * 0.85, 0.0, gz + oz * 0.85)))
	for n: Node in _tree_chunks.get(c, []):
		if is_instance_valid(n):
			n.queue_free()
	var layers: Array = []
	var every: Array = []
	for ki in range(_tree_kits.size()):
		every.append_array(by_kit[ki])
	if every.is_empty():
		_tree_chunks[c] = layers
		return
	var centre := Vector3.ZERO
	for t: Transform3D in every:
		centre += t.origin
	centre /= float(every.size())
	var near_end := TREE_NEAR_FP * vis_mult if fp_mode else TREE_NEAR
	var margin := 1.5 if fp_mode else 6.0
	for ki in range(_tree_kits.size()):
		var spots: Array = by_kit[ki]
		if spots.is_empty():
			continue
		for p: Dictionary in _tree_kits[ki]:
			layers.append(_tree_layer(p, spots, centre, 0.0, near_end, margin))
	for p: Dictionary in _far_tree_parts:
		layers.append(_tree_layer(p, every, centre, near_end, TREE_FAR_FP * vis_mult if fp_mode else 0.0, margin))
	_tree_chunks[c] = layers


## One part of one tree kit for a chunk. Every layer of a chunk sits at the same centre (the mean of
## all its trees) so visibility range distances are measured per chunk and the layers complement.
## Parts with "tint" get a hashed per-tree colour.
func _tree_layer(part: Dictionary, spots: Array, centre: Vector3, begin: float, end: float, margin: float) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var tint := bool(part.get("tint", false))
	mm.use_colors = tint
	mm.mesh = part["mesh"]
	mm.instance_count = spots.size()
	var xf: Transform3D = part["xform"]
	for k in range(spots.size()):
		var t: Transform3D = spots[k]
		mm.set_instance_transform(k, Transform3D(t.basis, t.origin - centre) * xf)
		if tint:
			var hv := absi(hash(Vector2i(roundi(t.origin.x * 100.0), roundi(t.origin.z * 100.0))))
			var b := 0.82 + float(hv % 37) / 100.0
			mm.set_instance_color(k, Color(b * (0.95 + float((hv >> 8) % 11) / 100.0), b, b * (0.9 + float((hv >> 16) % 13) / 100.0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = centre
	if part.get("mat") != null:
		mmi.material_override = part["mat"]
	mmi.visibility_range_begin = begin
	mmi.visibility_range_begin_margin = margin if begin > 0.0 else 0.0
	mmi.visibility_range_end = end
	mmi.visibility_range_end_margin = margin if end > 0.0 else 0.0
	if fp_mode:
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if begin > 0.0:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trees_root.add_child(mmi)
	return mmi

func _build_district_borders() -> void:
	for d in range(D.MAYORS.size()):
		var lbl := Label3D.new()
		lbl.text = "%s\n%s" % [D.MAYORS[d]["name"], D.MAYORS[d]["district"]]
		lbl.font_size = 64
		lbl.outline_size = 14
		lbl.pixel_size = 0.006
		lbl.modulate = Color.from_string(str(D.MAYORS[d]["color"]), Color.WHITE)
		lbl.modulate.a = 0.55
		lbl.rotation_degrees = Vector3(-90, 0, 0)
		var center: Vector2 = [Vector2(5, 5), Vector2(26, 5), Vector2(15.5, 18.5), Vector2(5, 26), Vector2(26, 26)][d]
		lbl.position = Vector3(center.x, 0.03, center.y)
		_labels_root.add_child(lbl)
	_rebuild_territory(-1)


## District borders, the dimmed unclaimed wilds, and markers on plots a mayor can annex.
func _rebuild_territory(_mi: int) -> void:
	if _territory_root != null:
		_territory_root.queue_free()
	_territory_root = Node3D.new()
	_territory_root.name = "Territory"
	add_child(_territory_root)
	_territory_root.visible = not fp_mode
	var strip_h := BoxMesh.new()
	strip_h.size = Vector3(1.0, 0.02, 0.05)
	var strip_v := BoxMesh.new()
	strip_v.size = Vector3(0.05, 0.02, 1.0)
	var edges: Array = []
	for _d in range(D.MAYORS.size()):
		edges.append([])
	for i in sim.active:
		var d := sim.district[i]
		if d < 0:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		for dv: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
			var nx := x + dv.x
			var ny := y + dv.y
			var nd := sim.district[D.idx(nx, ny)] if D.in_bounds(nx, ny) else -1
			# Shared borders are drawn once by the lower index; borders with the wilds by the owner.
			if nd == d or (nd >= 0 and nd < d):
				continue
			(edges[d] as Array).append(Vector3(x + dv.x * 0.5, 0.07, y + dv.y * 0.5))
			(edges[d] as Array).append(dv.x != 0)
	for d in range(D.MAYORS.size()):
		var col := Color.from_string(str(D.MAYORS[d]["color"]), Color.WHITE)
		var list: Array = edges[d]
		for vertical in [true, false]:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = strip_v if vertical else strip_h
			var spots: Array[Vector3] = []
			for k in range(0, list.size(), 2):
				if bool(list[k + 1]) == vertical:
					spots.append(list[k])
			mm.instance_count = spots.size()
			for k in range(spots.size()):
				mm.set_instance_transform(k, Transform3D(Basis(), spots[k]))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = _mat("border", col, 1.6, 0.8)
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_territory_root.add_child(mmi)
	# Surveyed but unclaimed plots are dimmed; the unsurveyed frontier (and the woods beyond the
	# world edge) sits under a haze that lifts plot by plot as the city grows towards it.
	var surveyed := {}
	for p: Vector2i in sim.surveyed_plots():
		surveyed[p] = true
	var dim: Array[Rect2i] = []
	var haze: Array[Rect2i] = []
	var plo := D.plot_of(D.X0, D.Y0)
	var phi := D.plot_of(D.X0 + D.W - 1, D.Y0 + D.H - 1)
	for py in range(plo.y, phi.y + 1):
		for px in range(plo.x, phi.x + 1):
			var p := Vector2i(px, py)
			if sim.plot_claimed(p):
				continue
			if surveyed.has(p):
				dim.append(D.plot_rect(p))
			else:
				haze.append(D.plot_rect(p))
	var e := TREE_RING + 4
	haze.append(Rect2i(D.X0 - e, D.Y0 - e, D.W + 2 * e, e))
	haze.append(Rect2i(D.X0 - e, D.Y0 + D.H, D.W + 2 * e, e))
	haze.append(Rect2i(D.X0 - e, D.Y0, e, D.H))
	haze.append(Rect2i(D.X0 + D.W, D.Y0, e, D.H))
	var wild := MeshInstance3D.new()
	wild.mesh = _rects_mesh(dim, 0.05)
	wild.material_override = _mat("wilds", Color(0.05, 0.07, 0.1), 0.0, 0.32)
	wild.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_territory_root.add_child(wild)
	var fog := MeshInstance3D.new()
	fog.name = "FrontierHaze"
	fog.mesh = _rects_mesh(haze, 1.1)
	fog.material_override = _mat("frontier_haze", Color(0.7, 0.76, 0.84), 0.0, 0.62)
	fog.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_territory_root.add_child(fog)
	var marked := {}
	for mi in range(D.MAYORS.size()):
		for p: Dictionary in sim.annexable_plots(mi):
			var key := "%d,%d" % [int(p["px"]), int(p["py"])]
			if marked.has(key):
				continue
			marked[key] = true
			var lbl := Label3D.new()
			lbl.text = "Unclaimed land\n%d open · %d woods · %d water" % [int(p["open_land"]), int(p["forest"]), int(p["water"])]
			lbl.font_size = 56
			lbl.outline_size = 12
			lbl.pixel_size = 0.006
			lbl.modulate = Color(0.85, 0.9, 1.0, 0.45)
			lbl.rotation_degrees = Vector3(-90, 0, 0)
			lbl.position = Vector3(int(p["x"]) + 7.5, 0.6, int(p["y"]) + 7.5)
			_territory_root.add_child(lbl)

func _build_cursor() -> void:
	_cursor = MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = 0.42
	t.outer_radius = 0.5
	t.ring_segments = 4
	t.rings = 16
	_cursor.mesh = t
	_cursor.rotation_degrees.y = 45.0
	_cursor.scale = Vector3(1.0, 0.2, 1.0)
	_cursor.material_override = _mat("cursor", Color(1, 1, 1), 2.0, 0.85)
	_cursor.visible = false
	add_child(_cursor)


func _build_avatars() -> void:
	var centers := [Vector2(5, 7), Vector2(25, 7), Vector2(14, 13), Vector2(5, 24), Vector2(25, 24)]
	for d in range(D.MAYORS.size()):
		var col := Color.from_string(str(D.MAYORS[d]["color"]), Color.WHITE)
		var root := Node3D.new()
		root.position = Vector3(centers[d].x, 0.05, centers[d].y)
		_fx_root.add_child(root)
		var bot := _inst(B + "resident_bot.glb")
		if bot != null:
			bot.scale = Vector3.ONE * 1.25
			root.add_child(bot)
			for part in ["Visor", "Halo", "Core"]:
				var f := bot.find_child(part, true, false)
				if f is MeshInstance3D:
					(f as MeshInstance3D).material_override = _mat("bot", col, 2.8)
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.24
		tm.outer_radius = 0.3
		ring.mesh = tm
		ring.scale = Vector3(1, 0.3, 1)
		ring.position.y = 0.03
		ring.material_override = _mat("ring", col, 2.5)
		root.add_child(ring)
		var name_lbl := _label("%s" % D.MAYORS[d]["name"], 34, col.lightened(0.3))
		name_lbl.position = Vector3(0, 1.05, 0)
		root.add_child(name_lbl)
		var bubble := _label("", 28, Color(1, 1, 1))
		bubble.position = Vector3(0, 1.55, 0)
		bubble.width = 520.0
		bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		bubble.visible = false
		root.add_child(bubble)
		_avatars.append({"root": root, "target": root.position, "bubble": bubble, "bubble_t": 0.0, "home": root.position})


func _label(text: String, size: int, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.outline_size = 10
	l.pixel_size = 0.0038
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.modulate = col
	l.outline_modulate = Color(0.04, 0.06, 0.1, 0.95)
	return l


# ------------------------------------------------------------------ tiles

func rebuild_all(animate: bool) -> void:
	for i in sim.active:
		_build_tile(i, animate)
	_street.flush()
	_refresh_status()
	_sync_events()


## Changed tiles and their road neighbours (whose pieces and furniture depend on them) rebuild; so do
## neighbouring lots whose frontage turned. Orbit builds them now; on foot they join the queue.
func _on_tiles_changed(indices: PackedInt32Array) -> void:
	var todo := {}
	for i in indices:
		todo[i] = true
		var x := D.tx(i)
		var y := D.ty(i)
		for dv in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var nx: int = x + dv.x
			var ny: int = y + dv.y
			if not D.in_bounds(nx, ny):
				continue
			var j := D.idx(nx, ny)
			var nk := sim.kind[j]
			if nk == D.ROAD:
				todo[j] = true
			elif (D.is_zone(nk) or D.is_service(nk)) and _yaw_stale(j):
				todo[j] = true
	if fp_mode:
		for i: int in todo.keys():
			if not _queue.has(i):
				_queue[i] = 0.0
		return
	for i: int in todo.keys():
		_build_tile(i, true)
	_street.flush()
	_refresh_status()


## True when lot j's building no longer faces its frontage road (a road appeared or went next to it).
func _yaw_stale(j: int) -> bool:
	var holder: Node3D = _tile_nodes.get(j, null)
	if holder == null or not is_instance_valid(holder) or not holder.has_meta("building_xform"):
		return false
	var x := D.tx(j)
	var y := D.ty(j)
	var h := absi(x * 73856093 ^ y * 19349663)
	var want := deg_to_rad(_lot_yaw(j, h, D.is_zone(sim.kind[j])))
	var have := (holder.get_meta("building_xform") as Transform3D).basis.get_euler().y
	return absf(angle_difference(want, have)) > 0.01


## Builds every queued tile now (each emits tile_built), then the batched street props.
func flush_rebuild_queue() -> void:
	while not _queue.is_empty():
		var i: int = _queue.keys()[0]
		_build_tile(i, true)
		_queue.erase(i)
	_street.flush()


func reset_section_stats() -> void:
	section_us_max.clear()


## Records the time since t0 under name and returns now.
func _section(name: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	section_us_max[name] = maxi(int(section_us_max.get(name, 0)), now - t0)
	return now


## Tiles waiting in the FP rebuild queue.
func rebuild_pending() -> int:
	return _queue.size()


## FP rebuild queue, once per frame: nearest tiles to priority_point first until rebuild_budget_ms is
## spent (tile_built included), at least one tile per frame. A tile within REBUILD_DEFER_DIST that
## the camera sees waits until it leaves the view or REBUILD_DEFER_MAX_S of its own waiting pass, so
## buildings do not pop beside the player; a tile whose model is still loading on a thread waits too.
func _process_queue(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var budget := int(rebuild_budget_ms * 1000.0)
	var order: Array = []
	for i: int in _queue.keys():
		var d := Vector2(D.tx(i) - priority_point.x, D.ty(i) - priority_point.z).length_squared()
		order.append(Vector2(d, i))
	order.sort()
	var built := 0
	for e: Vector2 in order:
		var i := int(e.y)
		if e.x < REBUILD_DEFER_DIST * REBUILD_DEFER_DIST and float(_queue[i]) < REBUILD_DEFER_MAX_S and _in_view(i):
			_queue[i] = float(_queue[i]) + delta
			continue
		if not _models_ready(i):
			continue
		var tb := Time.get_ticks_usec()
		_build_tile(i, true)
		_section("one_tile", tb)
		_queue.erase(i)
		built += 1
		if Time.get_ticks_usec() - t0 >= budget:
			break
	if built > 0:
		var tf := Time.get_ticks_usec()
		_street.flush()
		_section("street_flush", tf)


func _in_view(i: int) -> bool:
	return camera != null and camera.is_inside_tree() and camera.is_position_in_frustum(Vector3(D.tx(i), 0.05, D.ty(i)))


## True when the scene tile i needs is loaded; otherwise starts (or polls) a threaded load so the
## queue never loads a building on the main thread.
func _models_ready(i: int) -> bool:
	var k := sim.kind[i]
	var path := ""
	if D.is_zone(k) or D.is_service(k):
		var h := absi(D.tx(i) * 73856093 ^ D.ty(i) * 19349663)
		path = _model_path(k, sim.level[i], h)
	if path.is_empty() or _scenes.has(path):
		return true
	return _warm_one(path)


## Starts loading the scenes at paths on worker threads (the streetscape feature warms every zone,
## service and prop model at setup); _process tunes them in as they finish.
func warm_scenes(paths: Array) -> void:
	if DisplayServer.get_name() == "headless":
		return
	for p: String in paths:
		if not _scenes.has(p) and ResourceLoader.exists(p):
			_warm_one(p)


## Polls one threaded load; true once the scene is in the cache. Headless runs (the dummy renderer's
## texture storage is not thread-safe) load on the main thread instead.
func _warm_one(path: String) -> bool:
	if _scenes.has(path):
		return true
	if not _warming.has(path):
		if DisplayServer.get_name() == "headless" or ResourceLoader.load_threaded_request(path, "PackedScene") != OK:
			_scene(path)
			return true
		_warming[path] = true
		return false
	var st := ResourceLoader.load_threaded_get_status(path)
	if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return false
	_warming.erase(path)
	var ps: PackedScene = ResourceLoader.load_threaded_get(path) as PackedScene if st == ResourceLoader.THREAD_LOAD_LOADED else null
	if ps != null:
		_tune_materials(ps)
	_scenes[path] = ps
	return true


## Finishes at most one warmed scene per frame (tuning instantiates it once).
func _poll_warming() -> void:
	for p: String in _warming.keys():
		if ResourceLoader.load_threaded_get_status(p) != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			_warm_one(p)
			return


## Scene paths a growing city can need on foot: every zone level option and service model.
func warm_paths() -> Array:
	var out: Array = []
	for k: int in [D.ZONE_R, D.ZONE_C, D.ZONE_I]:
		for l in range(1, 4):
			for p: Variant in _zone_options(k, l):
				out.append(str(p))
	for k: int in D.KIND_NAMES.keys():
		if D.is_service(k):
			var p := _model_path(k, 1, 0)
			if not p.is_empty():
				out.append(p)
	return out


func _road_mask(x: int, y: int) -> int:
	var m := 0
	if D.in_bounds(x, y - 1) and sim.kind[D.idx(x, y - 1)] == D.ROAD:
		m |= 1
	if D.in_bounds(x + 1, y) and sim.kind[D.idx(x + 1, y)] == D.ROAD:
		m |= 2
	if D.in_bounds(x, y + 1) and sim.kind[D.idx(x, y + 1)] == D.ROAD:
		m |= 4
	if D.in_bounds(x - 1, y) and sim.kind[D.idx(x - 1, y)] == D.ROAD:
		m |= 8
	return m


static func _rot_mask(m: int) -> int:
	# Yaw +90 deg maps N->W, E->N, S->E, W->S.
	var r := 0
	if m & 1:
		r |= 8
	if m & 2:
		r |= 1
	if m & 4:
		r |= 2
	if m & 8:
		r |= 4
	return r


## Returns [piece, yaw]. Every road set shares one contract: straight runs N-S, corner joins
## S+W, tee joins E+S+W, end opens to S, with north at -Z.
func _road_piece(mask: int) -> Array:
	var bits := 0
	for b in [1, 2, 4, 8]:
		if mask & b:
			bits += 1
	if bits >= 4:
		return ["cross", 0.0]
	var bases := []
	if bits == 3:
		bases = [["tee", 14]]
	elif bits == 2:
		bases = [["straight", 5], ["corner", 12]]
	elif bits == 1 and _real_roads and ResourceLoader.exists(REAL_ROADS["end"]):
		bases = [["end", 4]]
	else:
		return ["straight", 0.0 if (mask & 5) != 0 or mask == 0 else 90.0]
	for base: Array in bases:
		var m: int = base[1]
		for k in range(4):
			if m == mask:
				return [base[0], float(k) * 90.0]
			m = _rot_mask(m)
	return ["straight", 0.0]


func _road_path(piece: String) -> String:
	if _real_roads and ResourceLoader.exists(str(REAL_ROADS.get(piece, ""))):
		return REAL_ROADS[piece]
	match piece:
		"lights":
			return ROAD_LIGHTS
		"corner":
			return ROAD_CORNER
		"tee":
			return ROAD_SPLIT
		"cross":
			return ROAD_CROSS
	return ROAD_STRAIGHT


func _build_tile(i: int, animate: bool) -> void:
	var k := sim.kind[i]
	var l := sim.level[i]
	var x := D.tx(i)
	var y := D.ty(i)
	var was_kind := _prev_kind[i]
	var was_level := _prev_level[i]
	_prev_kind[i] = k
	_prev_level[i] = l
	_queue.erase(i)
	_street.forget(i)
	var had := _tile_nodes.has(i)
	if _tile_nodes.has(i):
		(_tile_nodes[i] as Node3D).queue_free()
		_tile_nodes.erase(i)
	bus_stops.erase(i)
	if k == D.FOREST or was_kind == D.FOREST:
		_dirty_trees_at(x, y)
	# Woods are drawn by the tree chunks; only a burning forest needs its own node.
	if k == D.EMPTY or (k == D.FOREST and sim.burning[i] == 0):
		if had:
			tile_cleared.emit(i)
		return
	var holder := Node3D.new()
	holder.position = Vector3(x, 0.0, y)
	_tiles_root.add_child(holder)
	_tile_nodes[i] = holder
	var h := absi(x * 73856093 ^ y * 19349663)
	var model: Node3D = null
	var site: Dictionary = sim.sites.get(i, {})
	match k:
		D.ROAD:
			var mask := _road_mask(x, y)
			var piece := _road_piece(mask)
			var kind_name: String = piece[0]
			var on_water := sim.terrain[i] == D.WATER
			if kind_name == "straight" and on_water and _real_roads and ResourceLoader.exists(REAL_ROADS["bridge"]):
				kind_name = "bridge"
			elif kind_name == "straight" and (x + y) % 4 == 0:
				kind_name = "lights"
			model = _inst(_road_path(kind_name))
			if model != null:
				model.rotation_degrees.y = piece[1]
				holder.add_child(model)
			if kind_name == "bridge":
				pass
			elif on_water:
				var deck := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(1.0, 0.12, 1.0)
				deck.mesh = bm
				deck.position.y = WS.GROUND_Y - 0.06
				deck.material_override = _mat("bridge", Color(0.45, 0.45, 0.5))
				holder.add_child(deck)
			else:
				_maybe_bus_stop(i, x, y, holder)
			if fp_mode:
				_street.dress_road(i, holder, mask, kind_name, model)
		D.FOREST:
			pass
		D.ZONE_R, D.ZONE_C, D.ZONE_I:
			var lv := l
			if not site.is_empty() and str(site["plan"]) == "zone_up" and sim.site_stage_name(site) == "finishing":
				lv = int(site["target_level"])
			if not site.is_empty() and str(site["plan"]) != "zone_up":
				_build_site(i, holder, site, h)
			elif fp_mode and lv == 0:
				# A vacant lot on foot: rough ground and a "For lease" board, no zoning glow.
				_street.empty_lot(i, holder, k, h)
			else:
				var zc: Color = ZONE_COLORS[k]
				var pick := ""
				if lv > 0:
					var opts := _zone_options(k, lv)
					pick = str(opts[(h >> 3) % opts.size()])
				var pad := MeshInstance3D.new()
				var pm := PlaneMesh.new()
				pm.size = Vector2(0.96, 0.96) if lv > 0 else Vector2(0.94, 0.94)
				pad.mesh = pm
				pad.position.y = WS.PAD_TOP if fp_mode else ORBIT_PAD_Y
				if lv == 0:
					pad.material_override = _mat("zone", zc, 0.25, 0.85)
					holder.add_child(pad)
				elif fp_mode and (pick.begins_with(R) or k == D.ZONE_R):
					# On foot the real model's own lot slab shows its paving, tree pits and parking.
					pad.free()
				elif k == D.ZONE_C:
					pad.material_override = _pbr("sidewalk", Color(0.6, 0.6, 0.58), 1.0 / (3.0 * WS.M) if fp_mode else 1.0)
					holder.add_child(pad)
				elif k == D.ZONE_I:
					pad.material_override = _pbr("asphalt", Color(0.3, 0.3, 0.3), 1.0 / (3.0 * WS.M) if fp_mode else 0.8, Color(0.85, 0.85, 0.85))
					holder.add_child(pad)
				else:
					pad.free()
				if lv > 0:
					model = _inst(pick)
					if model != null:
						var s := 0.95
						if pick.begins_with(R):
							s = REAL_SCALE
						elif pick.begins_with(M + "zones/"):
							s = 0.9
						elif not pick.begins_with(B):
							s = 0.86
						# Real models are authored at their true height; only the stand-ins get height jitter.
						model.scale = Vector3.ONE * s if pick.begins_with(R) else Vector3(s, s * (0.9 + float(h % 5) * 0.06), s)
						model.rotation_degrees.y = _lot_yaw(i, h, true)
						holder.add_child(model)
					if fp_mode:
						_street.dress_lot(i, holder, k, lv, h)
					else:
						_add_zone_prop(k, h, holder)
				else:
					var post := MeshInstance3D.new()
					var cm := CylinderMesh.new()
					cm.top_radius = 0.025
					cm.bottom_radius = 0.025
					cm.height = 0.25
					post.mesh = cm
					post.position = Vector3(0.32, 0.125, -0.32)
					post.material_override = _mat("post", zc, 1.5)
					holder.add_child(post)
				if not site.is_empty():
					_build_site(i, holder, site, h, model)
		D.SITE:
			_build_site(i, holder, site, h)
		D.RUBBLE:
			var dirt := MeshInstance3D.new()
			if fp_mode:
				# On foot a closed slab of churned earth at PAD_TOP (the walkable height), no floating edge.
				var db := BoxMesh.new()
				db.size = Vector3(0.96, WS.PAD_TOP - WS.GROUND_Y, 0.96)
				dirt.mesh = db
				dirt.position.y = (WS.PAD_TOP + WS.GROUND_Y) * 0.5
				dirt.material_override = _pbr("dirt", Color(0.35, 0.3, 0.25), 1.0 / (3.0 * WS.M))
			else:
				var dm := PlaneMesh.new()
				dm.size = Vector2(0.96, 0.96)
				dirt.mesh = dm
				dirt.position.y = ORBIT_PAD_Y
				dirt.material_override = _pbr("dirt", Color(0.35, 0.3, 0.25), 1.0)
			holder.add_child(dirt)
			for r in range(5):
				var chunk := MeshInstance3D.new()
				var bm2 := BoxMesh.new()
				bm2.size = Vector3(0.18 + float((h >> r) % 3) * 0.06, 0.08 + float(r % 2) * 0.06, 0.16)
				chunk.mesh = bm2
				chunk.position = Vector3(float((h >> (r * 2)) % 7) * 0.1 - 0.3, 0.05, float((h >> (r * 3)) % 7) * 0.1 - 0.3)
				chunk.rotation_degrees.y = float((h >> r) % 90)
				chunk.material_override = _mat("rubble", Color(0.35, 0.32, 0.3))
				holder.add_child(chunk)
		_:
			var spath := ""
			var real_file := R + "buildings/%s.glb" % ("police_station" if k == D.POLICE else str(D.KIND_NAMES.get(k, "")))
			if ResourceLoader.exists(real_file):
				spath = real_file
			elif SERVICE_MODELS.has(k):
				spath = str(SERVICE_MODELS[k])
			elif NEW_SERVICE_MODELS.has(k):
				for p: String in NEW_SERVICE_MODELS[k]:
					if ResourceLoader.exists(M + p):
						spath = M + p
						break
			if not spath.is_empty():
				model = _inst(spath)
				if model != null:
					if spath.begins_with(R):
						model.scale = Vector3.ONE * REAL_SCALE
					model.rotation_degrees.y = _lot_yaw(i, h, false)
					holder.add_child(model)
					if fp_mode:
						_street.dress_service(i, holder, k, model)
					if k == D.COAL:
						for sn in ["StackTop_0", "StackTop_1"]:
							var top := model.find_child(sn, true, false) as Node3D
							if top != null:
								_add_smoke(top, Color(0.55, 0.55, 0.58))
					elif k == D.POLICE or k == D.FIRE:
						var beacon := model.find_child("Beacon", true, false) as Node3D
						if beacon != null:
							var light := OmniLight3D.new()
							light.light_color = Color(0.3, 0.5, 1.0) if k == D.POLICE else Color(1.0, 0.25, 0.2)
							light.omni_range = 1.2
							light.light_energy = 0.8
							beacon.add_child(light)
	if model != null and k != D.ROAD:
		holder.set_meta("building_path", model.scene_file_path)
		holder.set_meta("building_xform", model.transform)   # final transform, before the grow tween
	if model != null:
		_register_animated(model)
		_dress_windows(model, h)
		if fp_mode and k != D.ROAD:
			_street.dress_model(model)
	if k == D.ZONE_I and l >= 2 and model != null:
		var st := model.find_child("StackTop_0", true, false) as Node3D
		if st != null:
			_add_smoke(st, Color(0.5, 0.48, 0.44))
	if sim.burning[i] > 0:
		_add_fire(holder, model)
	if animate and model != null and (was_kind != k or l > was_level) and k != D.ROAD and k != D.FOREST:
		if fp_mode:
			# On foot buildings do not squash and spring; a small puff only when it happens nearby.
			if Vector2(x - priority_point.x, y - priority_point.z).length() < 4.0:
				_dust_puff(Vector3(x, 0.02, y))
		else:
			var target_scale := model.scale
			model.scale = Vector3(target_scale.x, target_scale.y * 0.05, target_scale.z)
			var tw := create_tween()
			tw.tween_property(model, "scale", target_scale, 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			_dust_puff(Vector3(x, 0.1, y))
	if fp_mode and not holder.has_meta("colliders") and k == D.ROAD:
		holder.set_meta("colliders", [])
	tile_built.emit(i, holder)


## Draws an open construction site: kit stage visuals sized to the building it will become.
func _build_site(i: int, holder: Node3D, s: Dictionary, h: int, existing: Node3D = null) -> void:
	if s.is_empty():
		return
	var stage := sim.site_stage_name(s)
	var ctx := {"h": h, "water": sim.terrain[i] == D.WATER}
	var f := directory.frontage(i) if directory != null else -1
	if f >= 0:
		ctx["front"] = Vector2i(D.tx(f) - D.tx(i), D.ty(f) - D.ty(i))
	var tk := int(s["target_kind"])
	var tl := maxi(int(s["target_level"]), 1)
	match str(s["type"]):
		"road":
			ctx["axis"] = _site_axis(i)
		"demolish":
			if str(s["plan"]) == "demolish" and stage == "demolition":
				ctx["old"] = _model_for(int(s["from_kind"]), maxi(int(s["from_level"]), 1), h, i)
		_:
			var bb := _model_bounds(tk, tl, h)
			var side := maxf(bb.size.x, bb.size.z)
			ctx["height"] = bb.end.y
			ctx["foot"] = Vector2(side, side)
			if existing != null:
				ctx["base_height"] = _model_bounds(tk, int(s["from_level"]), h).end.y
			elif stage == "finishing":
				var target := _model_for(tk, tl, h, i)
				if target != null:
					_dress_windows(target, h)
					if fp_mode:
						_street.dress_model(target)
					ctx["target"] = target
	var root: Node3D = kit.build_site(holder, s, stage, _stage_fraction(s), ctx)
	_register_animated(root)


## Stage progress, run forward through the current tick at the site's recent work rate so
## crews visibly advance between sim ticks instead of jumping once per tick.
func _stage_fraction(s: Dictionary) -> float:
	var p := float(s["progress"]) + float(s.get("rate", 0.0)) * sim.tick_phase()
	return clampf(p / maxf(float(s["stage_work"]), 0.01), 0.0, 1.0)


func _animate_sites(delta: float) -> void:
	if kit == null:
		return
	kit.animate(delta, _time)
	_site_timer += delta
	if _site_timer < 0.15:
		return
	_site_timer = 0.0
	for i: int in sim.sites.keys():
		if _tile_nodes.has(i):
			kit.update_site(_tile_nodes[i], _stage_fraction(sim.sites[i]))


func _site_axis(i: int) -> String:
	var x := D.tx(i)
	var y := D.ty(i)
	var ew := int(_roadish(x + 1, y)) + int(_roadish(x - 1, y))
	var ns := int(_roadish(x, y + 1)) + int(_roadish(x, y - 1))
	return "x" if ew > ns else "z"


func _roadish(x: int, y: int) -> bool:
	if not D.in_bounds(x, y):
		return false
	var j := D.idx(x, y)
	return sim.kind[j] == D.ROAD or (sim.sites.has(j) and int(sim.sites[j]["target_kind"]) == D.ROAD)


## Model file for a finished tile of kind k at density l, or "" when it has none.
func _model_path(k: int, l: int, h: int) -> String:
	if D.is_zone(k):
		if l <= 0:
			return ""
		var opts := _zone_options(k, l)
		return str(opts[(h >> 3) % opts.size()])
	var real_file := R + "buildings/%s.glb" % ("police_station" if k == D.POLICE else str(D.KIND_NAMES.get(k, "")))
	if ResourceLoader.exists(real_file):
		return real_file
	if SERVICE_MODELS.has(k):
		return str(SERVICE_MODELS[k])
	if NEW_SERVICE_MODELS.has(k):
		for p: String in NEW_SERVICE_MODELS[k]:
			if ResourceLoader.exists(M + p):
				return M + p
	return ""


func _model_scale(path: String, zone: bool, h: int) -> Vector3:
	if path.begins_with(R):
		return Vector3.ONE * REAL_SCALE
	if not zone:
		return Vector3.ONE
	var s := 0.86
	if path.begins_with(M + "zones/"):
		s = 0.9
	elif path.begins_with(B):
		s = 0.95
	return Vector3(s, s * (0.9 + float(h % 5) * 0.06), s)


## The finished model of kind k at density l for a tile with hash h, scaled and turned. With a tile
## index, zone and service models face that lot's frontage road.
func _model_for(k: int, l: int, h: int, i: int = -1) -> Node3D:
	var path := _model_path(k, l, h)
	if path.is_empty():
		return null
	var m := _inst(path)
	if m == null:
		return null
	m.scale = _model_scale(path, D.is_zone(k), h)
	if i >= 0:
		m.rotation_degrees.y = _lot_yaw(i, h, D.is_zone(k))
	elif D.is_zone(k):
		m.rotation_degrees.y = float((h % 4) * 90)
	return m


## Model yaw (degrees) for lot i: its +Z face (doors, shopfronts) toward the frontage road
## (CityDirectory.frontage_yaw); without a frontage, zones keep the hashed quarter turn and
## services face south.
func _lot_yaw(i: int, h: int, zone: bool) -> float:
	var fy := directory.frontage_yaw(i) if directory != null else NAN
	if not is_nan(fy):
		return fy
	return float((h % 4) * 90) if zone else 0.0


## Scaled bounds of the model a tile would show, cached per file.
func _model_bounds(k: int, l: int, h: int) -> AABB:
	var path := _model_path(k, l, h)
	if path.is_empty():
		return AABB(Vector3(-0.35, 0, -0.35), Vector3(0.7, 0.3, 0.7))
	var b := _local_bounds(path)
	var sc := _model_scale(path, D.is_zone(k), h)
	return AABB(b.position * sc, b.size * sc)


## Unscaled bounds of a model file in its own space, cached per file.
func _local_bounds(path: String) -> AABB:
	if not _bounds_cache.has(path):
		var bb := AABB(Vector3(-0.35, 0, -0.35), Vector3(0.7, 0.5, 0.7))
		var n := _inst(path)
		if n != null:
			var parts: Array = []
			_collect_meshes(n, Transform3D.IDENTITY, parts)
			for e: Dictionary in parts:
				var a: AABB = (e["xform"] as Transform3D) * (e["mesh"] as Mesh).get_aabb()
				bb = a if e == parts[0] else bb.merge(a)
			n.free()
		_bounds_cache[path] = bb
	return _bounds_cache[path]


## World-space bounds of the building model on tile i (zone or service); AABB() (size zero) when the
## tile has no building model: roads, rubble, sites without a model, empty land, woods.
func building_aabb(i: int) -> AABB:
	var holder: Node3D = _tile_nodes.get(i, null)
	if holder == null or not is_instance_valid(holder) or not holder.has_meta("building_path"):
		return AABB()
	var path := str(holder.get_meta("building_path"))
	if path.is_empty():
		return AABB()
	var local := _local_bounds(path)
	return holder.transform * ((holder.get_meta("building_xform") as Transform3D) * local)


## World-space blocking boxes of the construction site drawn on tile i, one per entry of the
## `colliders` meta that ConstructionKit.build_site writes on the holder's "Site" node before
## tile_built fires: hoarding segments (with the gate gap), machine bodies (stretched over their
## shuttle run, without the swinging arms), the crane's base and mast, the floodlight pole, slabs,
## formwork, berms, mounds, the frame, the scaffold and the old or finished building. Each entry is
## a box yawed about +Y; this returns the box of its rotated corners. Parts can reach past the
## tile (a tower crane's base up to 0.2 u into the neighbours). [] when no site is drawn on tile i.
func site_boxes(i: int) -> Array[AABB]:
	var out: Array[AABB] = []
	var site := _site_root(i)
	if site == null:
		return out
	var holder := site.get_parent() as Node3D
	for c: Dictionary in site.get_meta("colliders", []):
		out.append(holder.transform * ConstructionKit.collider_aabb(c))
	return out


## The open side of site i's hoarding (ConstructionKit._fence: toward the frontage road), or
## Vector2i.ZERO without a fenced site drawn on tile i.
func site_gate(i: int) -> Vector2i:
	var site := _site_root(i)
	return site.get_meta("gate", Vector2i.ZERO) if site != null else Vector2i.ZERO


## Where people stand on site i's own parts as drawn now (ConstructionKit.decks_of: the pit, the
## slab as poured, the frame's floors shown so far, the scaffold's boards), in world space.
func site_decks(i: int) -> Array[Dictionary]:
	var site := _site_root(i)
	if site == null:
		var none: Array[Dictionary] = []
		return none
	return ConstructionKit.decks_of(site, (site.get_parent() as Node3D).transform)


func _site_root(i: int) -> Node3D:
	var holder: Node3D = _tile_nodes.get(i, null)
	if holder == null or not is_instance_valid(holder):
		return null
	return holder.get_node_or_null("Site") as Node3D


## Merged world-space bound of site_boxes(i): contains every blocking part the construction kit
## drew for the site on tile i, and can reach past the tile. AABB() when no site is drawn. For
## movement use site_boxes(i): this bound also covers the gaps between parts (the hoarding gate).
func site_bounds(i: int) -> AABB:
	var b := AABB()
	for a: AABB in site_boxes(i):
		b = a if b.size == Vector3.ZERO else b.merge(a)
	return b


## The Node3D holding everything drawn on tile i, or null.
func tile_holder(i: int) -> Node3D:
	return _tile_nodes.get(i, null)


## Camera used for picking, shake and avatar picking (orbit rig camera or the FP camera).
func set_camera(c: Camera3D) -> void:
	camera = c
	if avatars != null:
		avatars.camera = c

## Zone models for a density level: the hand-made defaults plus every GLB in models/zones/<r|c|i><level>/.
func _zone_options(k: int, l: int) -> Array:
	var key := "zone_%d_%d" % [k, l]
	if not _catalogs.has(key):
		var letter := "r" if k == D.ZONE_R else ("c" if k == D.ZONE_C else "i")
		# A full realistic set replaces the stand-ins outright so styles never mix on one street.
		var opts: Array = _list_glbs(R + "zones/%s%d/" % [letter, l], "")
		if opts.size() < 3:
			opts = (ZONE_MODELS[k][l] as Array).duplicate()
			opts.append_array(_list_glbs(M + "zones/%s%d/" % [letter, l], ""))
		_catalogs[key] = opts
	return _catalogs[key]


func _list_glbs(dir_path: String, prefix: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		# Exported builds list "<name>.glb.import" instead of the source file.
		var n := f.trim_suffix(".import").trim_suffix(".remap")
		if n.ends_with(".glb") and n.begins_with(prefix) and not out.has(dir_path + n):
			out.append(dir_path + n)
	out.sort()
	return out


func _props(prefix: String) -> Array:
	var key := "prop_" + prefix
	if not _catalogs.has(key):
		var real := _list_glbs(R + "props/", prefix)
		_catalogs[key] = real if not real.is_empty() else _list_glbs(M + "props/", prefix)
	return _catalogs[key]


func _add_zone_prop(k: int, h: int, holder: Node3D) -> void:
	if h % 3 == 0:
		return
	var pool: Array = R_PROPS if k == D.ZONE_R else (C_PROPS if k == D.ZONE_C else I_PROPS)
	var opts := _props(str(pool[(h >> 5) % pool.size()]))
	if opts.is_empty():
		return
	var prop := _inst(str(opts[(h >> 7) % opts.size()]))
	if prop == null:
		return
	var corner := (h >> 9) % 4
	var cx := 0.4 if corner % 2 == 0 else -0.4
	var cz := 0.4 if corner < 2 else -0.4
	prop.position = Vector3(cx, 0.0, cz)
	prop.rotation_degrees.y = float(((h >> 11) % 4) * 90)
	prop.set_meta("prop", true)
	if prop.scene_file_path == R + "props/billboard.glb":
		prop.set_meta("poster_slot", STREET.billboard_slot())
	holder.add_child(prop)
	_register_animated(prop)


## Bus stops sit on the sidewalk of straight roads that face built-up homes or shops.
func _maybe_bus_stop(i: int, x: int, y: int, holder: Node3D) -> void:
	var mask := _road_mask(x, y)
	if (mask != 5 and mask != 10) or (x * 7 + y * 3) % 5 != 0:
		return
	var sides := [Vector2i(1, 0), Vector2i(-1, 0)] if mask == 5 else [Vector2i(0, 1), Vector2i(0, -1)]
	for dv: Vector2i in sides:
		var nx := x + dv.x
		var ny := y + dv.y
		if not D.in_bounds(nx, ny):
			continue
		var nk := sim.kind[D.idx(nx, ny)]
		if (nk == D.ZONE_R or nk == D.ZONE_C) and sim.level[D.idx(nx, ny)] > 0:
			var stop: Node3D = _street.shelter(holder, dv) if fp_mode else null
			if stop == null:
				stop = _inst(M + "props/bus_stop.glb")
				if stop == null:
					stop = _proc_bus_stop()
				stop.position = Vector3(dv.x * 0.43, 0.0, dv.y * 0.43)
				# The shelter's open side (+Z) faces the road.
				stop.rotation.y = atan2(-float(dv.x), -float(dv.y))
				stop.set_meta("prop", true)
				stop.set_meta("poster_slot", {"kind": "bus_shelter", "size": Vector2(0.08, 0.09), "xform": Transform3D(Basis(), Vector3(0.10, 0.09, -0.0555))})
				holder.add_child(stop)
			bus_stops[i] = dv
			return


func _proc_bus_stop() -> Node3D:
	var root := Node3D.new()
	var roof := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(0.3, 0.02, 0.1)
	roof.mesh = rm
	roof.position.y = 0.2
	roof.material_override = _mat("stop_roof", Color(0.2, 0.45, 0.85))
	root.add_child(roof)
	var back := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.3, 0.19, 0.012)
	back.mesh = bm
	back.position = Vector3(0, 0.1, -0.045)
	back.material_override = _mat("stop_glass", Color(0.6, 0.8, 0.95), 0.2, 0.5)
	root.add_child(back)
	return root


## Rotor* parts spin; Beacon* parts blink; Floodlight* and Bulb* parts glow.
func _register_animated(model: Node3D) -> void:
	for n in model.find_children("Rotor*", "", true, false):
		_spinners.append(n as Node3D)
	for n in model.find_children("Beacon*", "", true, false):
		_blinkers.append({"node": n, "phase": randf() * TAU})
	for pat in ["Floodlight*", "Bulb*", "Lamp*"]:
		for n in model.find_children(pat, "", true, false):
			if n is MeshInstance3D:
				(n as MeshInstance3D).material_override = _lamp_material()
				if pat == "Bulb*" and model.is_inside_tree():
					_add_light_pool(model, n as Node3D)


## Fake pool of lamplight on the ground: an additive radial quad that fades in after dark. On foot
## an emissive decal instead, which lies on the road, kerb and paving rather than floating over them.
func _add_light_pool(model: Node3D, bulb: Node3D) -> void:
	if fp_mode and _street != null:
		_street.light_pool(model, model.to_local(bulb.global_position))
		return
	if _pool_mat == null:
		var grad := Gradient.new()
		grad.set_color(0, Color(1, 1, 1, 1))
		grad.set_color(1, Color(0, 0, 0, 1))
		var tex := GradientTexture2D.new()
		tex.gradient = grad
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 64
		tex.height = 64
		_pool_mat = StandardMaterial3D.new()
		_pool_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_pool_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_pool_mat.albedo_texture = tex
		_pool_mat.disable_receive_shadows = true
		_apply_night()
	var pool := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.42, 0.42)
	pool.mesh = pm
	pool.material_override = _pool_mat
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model.add_child(pool)
	var p := model.to_local(bulb.global_position)
	pool.position = Vector3(p.x, 0.015, p.z)


## Swaps WindowLit surfaces for shared glass that turns into lit rooms after dark.
func _dress_windows(model: Node3D, h: int) -> void:
	var variant := (h >> 4) % WINDOW_TINTS.size()
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var whole := str(mi.name).begins_with("WindowLit")
		for s in range(mi.mesh.get_surface_count()):
			var m := mi.mesh.surface_get_material(s)
			if whole or (m != null and m.resource_name.begins_with("WindowLit")):
				mi.set_surface_override_material(s, _window_material(variant))


func _window_material(v: int) -> Material:
	if fp_mode and ResourceLoader.exists(WINDOW_SHADER):
		if _window_fp_mat == null:
			_window_fp_mat = ShaderMaterial.new()
			_window_fp_mat.shader = load(WINDOW_SHADER)
			_window_fp_mat.set_shader_parameter("night", night)
		return _window_fp_mat
	if _window_mats.is_empty():
		for t: Color in WINDOW_TINTS:
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.15, 0.19, 0.25)
			m.metallic = 0.3
			m.roughness = 0.14
			m.emission_enabled = true
			m.emission = t
			_window_mats.append(m)
		_apply_night()
	return _window_mats[v % _window_mats.size()]


func _lamp_material() -> StandardMaterial3D:
	if _lamp_mat == null:
		_lamp_mat = StandardMaterial3D.new()
		_lamp_mat.albedo_color = Color(1.0, 0.93, 0.75)
		_lamp_mat.emission_enabled = true
		_lamp_mat.emission = Color(1.0, 0.85, 0.6)
		_apply_night()
	return _lamp_mat


func set_night(n: float) -> void:
	if absf(n - night) < 0.004:
		return
	night = n
	_apply_night()


func _apply_night() -> void:
	var glow := smoothstep(0.25, 0.85, night)
	for k in range(_window_mats.size()):
		_window_mats[k].emission_energy_multiplier = float(WINDOW_GLOW[k]) * glow
	if _lamp_mat != null:
		# From above a faint glow keeps the lamps readable by day; on foot an unlit lamp is frosted
		# glass, so it lights up only toward dusk.
		_lamp_mat.emission_energy_multiplier = (0.0 if fp_mode else 0.4) + 5.0 * glow
		_lamp_mat.albedo_color = Color(0.78, 0.76, 0.72) if fp_mode else Color(1.0, 0.93, 0.75)
	if _pool_mat != null:
		_pool_mat.albedo_color = Color(1.0, 0.78, 0.5) * (0.55 * glow)
	for key: String in _mats.keys():
		if key.begins_with("zone_"):
			# Unbuilt zoning stays readable by day without glowing like neon at night.
			(_mats[key] as StandardMaterial3D).emission_energy_multiplier = 0.25 * (1.0 - 0.8 * glow)
	if _water_mat != null:
		_water_mat.set_shader_parameter("night", night)
	if _window_fp_mat != null:
		_window_fp_mat.set_shader_parameter("night", glow)
	if _street != null:
		_street.set_night(glow)


func _animate_parts(delta: float) -> void:
	# Parts of rebuilt tiles are freed; drop them before touching them as typed nodes.
	var live_s: Array = []
	for n: Variant in _spinners:
		if is_instance_valid(n) and (n as Node3D).is_inside_tree():
			(n as Node3D).rotate_object_local(ROTOR_AXIS, delta * 2.4)
			live_s.append(n)
	_spinners = live_s
	var live_b: Array[Dictionary] = []
	for b in _blinkers:
		var n: Variant = b["node"]
		if is_instance_valid(n) and (n as Node3D).is_inside_tree():
			(n as Node3D).visible = sin(_time * 3.0 + float(b["phase"])) > -0.3
			live_b.append(b)
	_blinkers = live_b


func _add_smoke(parent: Node3D, col: Color) -> void:
	var p := CPUParticles3D.new()
	p.amount = 14
	p.lifetime = 2.6
	p.direction = Vector3(0.2, 1, 0)
	p.spread = 12.0
	p.initial_velocity_min = 0.25
	p.initial_velocity_max = 0.4
	p.gravity = Vector3(0.05, 0.05, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	if fp_mode:
		# Street scale: a stack plume rising at walking-to-jogging pace, puffs a few metres across.
		p.lifetime = 6.0
		p.initial_velocity_min = 1.5 * WS.M
		p.initial_velocity_max = 2.5 * WS.M
		p.gravity = Vector3(0.4 * WS.M, 0.3 * WS.M, 0)
		p.scale_amount_min = 0.36
		p.scale_amount_max = 0.84
	var sm := SphereMesh.new()
	sm.radius = 0.07
	sm.height = 0.14
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = _mat("smoke", col, 0.0, 0.55)
	p.mesh = sm
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.4))
	curve.add_point(Vector2(1, 1.6))
	p.scale_amount_curve = curve
	parent.add_child(p)


func _add_fire(holder: Node3D, model: Node3D = null) -> void:
	var p := CPUParticles3D.new()
	p.amount = 26
	p.lifetime = 0.9
	p.direction = Vector3.UP
	p.spread = 25.0
	p.initial_velocity_min = 0.5
	p.initial_velocity_max = 1.0
	p.gravity = Vector3(0, 0.4, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.3, 0.1, 0.3)
	var radius := 0.08
	p.position.y = 0.4
	if fp_mode:
		# Flames a little over a metre across licking up at 2-3 m/s from the building's footprint.
		radius = 0.6 * WS.M
		p.amount = 60
		p.lifetime = 1.4
		p.initial_velocity_min = 2.0 * WS.M
		p.initial_velocity_max = 3.0 * WS.M
		p.gravity = Vector3(0, 1.0 * WS.M, 0)
		var foot := Vector2(0.7, 0.7)
		var top := 0.3
		if model != null and holder.has_meta("building_path"):
			var b := _local_bounds(str(holder.get_meta("building_path")))
			foot = Vector2(b.size.x, b.size.z) * model.scale.x
			top = b.end.y * model.scale.y
		p.emission_box_extents = Vector3(foot.x * 0.4, 0.4 * WS.M, foot.y * 0.4)
		p.position.y = clampf(top * 0.5, 0.05, 1.5)
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = _mat("flame", Color(1.0, 0.45, 0.1), 4.0, 0.9)
	p.mesh = sm
	p.color = Color(1, 0.7, 0.3)
	holder.add_child(p)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.5, 0.2)
	light.light_energy = 2.5
	light.omni_range = 2.2
	light.position.y = 0.8
	light.set_meta("flicker", true)
	holder.add_child(light)
	_flicker_lights.append(light)


func _dust_puff(pos: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 12
	p.lifetime = 0.8
	p.explosiveness = 0.9
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 0.4
	p.initial_velocity_max = 0.9
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = _mat("dust", Color(0.85, 0.8, 0.7), 0.0, 0.7)
	p.mesh = sm
	p.position = pos
	_fx_root.add_child(p)
	get_tree().create_timer(1.4).timeout.connect(p.queue_free)


# ------------------------------------------------------------------ status, overlays

func _refresh_status() -> void:
	if fp_mode:
		return
	var pm := _power_icons.multimesh
	var wm := _water_icons.multimesh
	var pc := 0
	var wc := 0
	for i in sim.active:
		var k := sim.kind[i]
		var needs := (D.is_zone(k) and sim.level[i] > 0) or (D.is_service(k) and k != D.PARK and not D.is_power_plant(k))
		if not needs:
			continue
		var top := 1.25 + (0.5 if sim.level[i] >= 3 else 0.0)
		if sim.powered[i] == 0:
			pm.set_instance_transform(pc, Transform3D(Basis(), Vector3(D.tx(i) - 0.12, top, D.ty(i))))
			pc += 1
		elif sim.watered[i] == 0 and D.is_zone(k):
			wm.set_instance_transform(wc, Transform3D(Basis(), Vector3(D.tx(i) + 0.12, top, D.ty(i))))
			wc += 1
	pm.visible_instance_count = pc
	wm.visible_instance_count = wc
	if overlay_mode != "none":
		_refresh_overlay()


func set_overlay(mode: String) -> void:
	if fp_mode and mode != "none":
		return
	overlay_mode = mode
	_overlay_mm.visible = mode != "none"
	# Data views hide the buildings so the value columns read clearly, like SimCity's info layers.
	var data_view := mode != "none" and mode != "districts"
	_tiles_root.visible = not data_view
	_cars_root.visible = not data_view
	_peds_root.visible = not data_view
	if life != null:
		life.visible = not data_view
	if mode != "none":
		_refresh_overlay()


func _ramp(v: float, a: Color, b: Color, alpha: float) -> Color:
	var c := a.lerp(b, clampf(v, 0.0, 1.0))
	c.a = alpha
	return c


func _refresh_overlay() -> void:
	var mm := _overlay_mm.multimesh
	var src: PackedFloat32Array = PackedFloat32Array()
	match overlay_mode:
		"pollution":
			src = sim.pollution
		"crime":
			src = sim.crime
		"land_value":
			src = sim.land_value
		"traffic":
			src = sim.traffic
	var lo := 1e9
	var hi := -1e9
	for v in src:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span := maxf(hi - lo, 0.05)
	for i in sim.active:
		var k := sim.kind[i]
		var c := Color(0, 0, 0, 0)
		var h := 0.0
		var n := clampf((src[i] - lo) / span, 0.0, 1.0) if not src.is_empty() else 0.0
		var built := 0.25 + 0.35 * float(sim.level[i]) if D.is_zone(k) else (0.7 if D.is_service(k) else 0.08)
		match overlay_mode:
			"power":
				if k != D.EMPTY and k != D.FOREST and k != D.RUBBLE:
					c = Color(0.2, 1.0, 0.35, 0.8) if sim.powered[i] == 1 else Color(1.0, 0.15, 0.15, 0.9)
					h = built
			"water":
				if sim.water_need(i) > 0.0 or k == D.PUMP:
					c = Color(0.2, 0.6, 1.0, 0.8) if sim.watered[i] == 1 else Color(1.0, 0.55, 0.1, 0.9)
					h = built
			"pollution":
				if sim.pollution[i] > 0.03:
					c = _ramp(n, Color(1.0, 0.92, 0.3), Color(0.5, 0.16, 0.02), 0.92)
					h = 0.05 + n * 2.2
			"crime":
				if sim.crime[i] > 0.02:
					c = _ramp(n, Color(0.55, 0.45, 1.0), Color(0.95, 0.0, 0.25), 0.92)
					h = 0.05 + n * 2.2
			"land_value":
				if terrain_is_land(i):
					c = _ramp(n, Color(0.85, 0.15, 0.15), Color(0.1, 0.9, 0.35), 0.92)
					h = 0.05 + n * 2.0
			"traffic":
				if k == D.ROAD:
					c = _ramp(n, Color(0.2, 1.0, 0.3), Color(1.0, 0.1, 0.1), 0.95)
					h = 0.05 + n * 1.6
			"happiness":
				if k == D.ZONE_R and sim.level[i] > 0:
					c = _ramp(sim.happiness[i], Color(1.0, 0.15, 0.15), Color(0.2, 1.0, 0.4), 0.85)
					h = built
			"districts":
				if sim.district[i] < 0:
					continue
				var dc := Color.from_string(str(D.MAYORS[sim.district[i]]["color"]), Color.WHITE)
				c = Color(dc.r, dc.g, dc.b, 0.35)
				h = 0.03
			"services":
				var v := maxf(maxf(maxf(sim.cov_police[i], sim.cov_fire[i]), maxf(sim.cov_health[i], sim.cov_school[i])), maxf(sim.cov_leisure[i], sim.cov_transit[i]))
				if v > 0.02:
					c = Color(0.2, 0.9, 1.0, 0.35 + v * 0.5)
					h = 0.05 + v * 1.4
				if D.is_service(k):
					c = Color(1.0, 1.0, 1.0, 0.95)
					h = 1.2
		mm.set_instance_color(i, c)
		mm.set_instance_transform(i, _column(i, h if c.a > 0.0 else 0.0))


func terrain_is_land(i: int) -> bool:
	return sim.terrain[i] != D.WATER


# ------------------------------------------------------------------ events

func _sync_events() -> void:
	var live := {}
	for ev in sim.events:
		live[int(ev["id"])] = ev
	for id: int in _event_nodes.keys():
		if not live.has(id):
			(_event_nodes[id] as Node3D).queue_free()
			_event_nodes.erase(id)
	for id: int in live.keys():
		if not _event_nodes.has(id):
			_event_nodes[id] = _make_event_fx(live[id])


func _make_event_fx(ev: Dictionary) -> Node3D:
	var t := str(ev["type"])
	var root := Node3D.new()
	root.position = Vector3(int(ev["x"]), 0.05, int(ev["y"]))
	root.set_meta("type", t)
	_fx_root.add_child(root)
	var col := Color(1, 0.5, 0.1)
	match t:
		"blackout":
			col = Color(1.0, 0.18, 0.33)
		"sewage_burst":
			col = Color(0.4, 0.9, 0.2)
			var puddle := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 1.6
			cm.bottom_radius = 1.7
			cm.height = 0.03
			puddle.mesh = cm
			puddle.material_override = _mat("sewage", Color(0.3, 0.6, 0.15), 1.2, 0.75)
			root.add_child(puddle)
		"gridlock":
			col = Color(1.0, 0.6, 0.1)
		"smog":
			col = Color(0.7, 0.65, 0.4)
			# On foot the streetscape weather tints the fog near the event instead of floating balls.
			for s in range(0 if fp_mode else 7):
				var puff := MeshInstance3D.new()
				var sm := SphereMesh.new()
				sm.radius = 1.0 + float(s % 3) * 0.3
				sm.height = sm.radius * 1.2
				puff.mesh = sm
				puff.position = Vector3(cos(float(s)) * 2.2, 1.2 + float(s % 2) * 0.5, sin(float(s) * 1.3) * 2.2)
				puff.material_override = _mat("smog", Color(0.62, 0.58, 0.42), 0.2, 0.32)
				puff.set_meta("drift", float(s))
				root.add_child(puff)
		"flood":
			col = Color(0.3, 0.6, 1.0)
			var fm := PlaneMesh.new()
			fm.size = Vector2(1, 1)
			for ti: Variant in ev.get("tiles", []):
				var w := MeshInstance3D.new()
				w.mesh = fm
				w.position = Vector3(D.tx(int(ti)) - int(ev["x"]), 0.12, D.ty(int(ti)) - int(ev["y"]))
				w.material_override = _mat("flood", Color(0.25, 0.5, 0.9), 0.4, 0.55)
				if fp_mode:
					# Ankle-deep water over the street, drawn like the river (root sits at y 0.05).
					w.position.y = WS.GROUND_Y + 0.008 - root.position.y
					if _water_mat != null:
						w.material_override = _water_mat
					w.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				root.add_child(w)
		"tornado":
			col = Color(0.75, 0.75, 0.8)
			var cone := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.9
			cyl.bottom_radius = 0.12
			cyl.height = 3.0
			cone.mesh = cyl
			cone.position.y = 1.5
			cone.material_override = _mat("tornado", Color(0.6, 0.62, 0.68), 0.3, 0.6)
			root.add_child(cone)
			root.set_meta("path", ev.get("tiles", []))
		"earthquake":
			col = Color(0.75, 0.5, 0.3)
		"fire":
			col = Color(1.0, 0.4, 0.1)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	var r := float(ev.get("radius", 3))
	tm.inner_radius = r - 0.12
	tm.outer_radius = r
	tm.rings = 48
	ring.mesh = tm
	ring.scale = Vector3(1, 0.15, 1)
	ring.position.y = 0.05
	ring.material_override = _mat("evring", col, 2.5, 0.8)
	ring.set_meta("pulse", true)
	ring.set_meta("orbit_only", true)
	ring.visible = not fp_mode
	root.add_child(ring)
	var lbl := _label("%s\n(%s)" % [ev["label"], ev.get("source", "")], 34, col.lightened(0.35))
	lbl.position.y = 2.6
	lbl.set_meta("orbit_only", true)
	lbl.visible = not fp_mode
	root.add_child(lbl)
	return root


# ------------------------------------------------------------------ AI presentation

func show_mayor_decision(mi: int, entry: Dictionary) -> void:
	if mi < 0 or mi >= _avatars.size():
		return
	var av: Dictionary = _avatars[mi]
	var focus: Vector2i = entry.get("focus", D.NO_TILE)
	if focus != D.NO_TILE:
		av["target"] = Vector3(focus.x + 0.4, 0.05, focus.y + 0.4)
	var bubble: Label3D = av["bubble"]
	var post := str(entry.get("post", ""))
	bubble.text = post if not post.is_empty() else str(entry.get("thought", "")).left(120)
	bubble.visible = not bubble.text.is_empty()
	av["bubble_t"] = 11.0


func show_mayor_thinking(mi: int) -> void:
	if mi < 0 or mi >= _avatars.size():
		return
	var bubble: Label3D = _avatars[mi]["bubble"]
	bubble.text = "thinking..."
	bubble.visible = true
	_avatars[mi]["bubble_t"] = 60.0


func show_citizen_voices(voices: Array) -> void:
	if fp_mode:
		return
	for b in _bubbles:
		if is_instance_valid(b["node"]):
			(b["node"] as Node3D).queue_free()
	_bubbles.clear()
	for v: Variant in voices.slice(0, 6):
		var vd: Dictionary = v
		var mood := str(vd.get("mood", "ok"))
		var col := Color(0.75, 1.0, 0.8)
		if mood == "upset":
			col = Color(1.0, 0.85, 0.5)
		elif mood == "angry":
			col = Color(1.0, 0.55, 0.5)
		var lbl := _label("%s: \"%s\"" % [vd.get("name", "Citizen"), vd.get("thought", "")], 24, col)
		lbl.width = 460.0
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.position = Vector3(int(vd["x"]), 1.5, int(vd["y"]))
		_labels_root.add_child(lbl)
		_bubbles.append({"node": lbl, "t": 10.0})


func avatar_position(mi: int) -> Vector3:
	if mi >= 0 and mi < _avatars.size():
		return (_avatars[mi]["root"] as Node3D).position
	return Vector3(15.5, 0, 15.5)


# ------------------------------------------------------------------ traffic & pedestrians

func _road_neighbors(p: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dv in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var n: Vector2i = p + dv
		if D.in_bounds(n.x, n.y) and sim.kind[D.idx(n.x, n.y)] == D.ROAD:
			out.append(n)
	return out


func _random_road(near_kind: int = -1) -> Vector2i:
	for _a in range(40):
		var i := sim.active[randi() % sim.active.size()]
		if sim.kind[i] != D.ROAD:
			continue
		var p := Vector2i(D.tx(i), D.ty(i))
		if near_kind < 0:
			return p
		for dv in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var n: Vector2i = p + dv
			if D.in_bounds(n.x, n.y) and sim.kind[D.idx(n.x, n.y)] == near_kind and sim.level[D.idx(n.x, n.y)] > 0:
				return p
	return D.NO_TILE


func _spawn_agent(is_car: bool) -> void:
	var start := _random_road(-1 if is_car else D.ZONE_R)
	if start == D.NO_TILE:
		return
	var nbrs := _road_neighbors(start)
	if nbrs.is_empty():
		return
	var node: Node3D
	if is_car:
		node = _inst(str(CAR_MODELS[randi() % CAR_MODELS.size()]))
		if node == null:
			return
		node.scale = Vector3.ONE * 0.17
		_cars_root.add_child(node)
	else:
		node = Node3D.new()
		var body := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.035
		cap.height = 0.16
		body.mesh = cap
		body.position.y = 0.09
		body.material_override = _mat("shirt", SHIRTS[randi() % SHIRTS.size()])
		node.add_child(body)
		var head := MeshInstance3D.new()
		var hs := SphereMesh.new()
		hs.radius = 0.03
		hs.height = 0.06
		head.mesh = hs
		head.position.y = 0.2
		head.material_override = _mat("skin", Color(0.9, 0.72, 0.56))
		node.add_child(head)
		_peds_root.add_child(node)
	var agent := {"node": node, "from": start, "to": nbrs[randi() % nbrs.size()], "t": 0.0, "speed": randf_range(1.3, 1.9) if is_car else randf_range(0.35, 0.55), "side": 0.12 if is_car else 0.42 * (1 if randf() < 0.5 else -1)}
	if is_car:
		_cars.append(agent)
	else:
		_peds.append(agent)


func _advance_agent(a: Dictionary, delta: float, is_car: bool) -> bool:
	var from: Vector2i = a["from"]
	var to: Vector2i = a["to"]
	if sim.kind[D.idx(to.x, to.y)] != D.ROAD or sim.kind[D.idx(from.x, from.y)] != D.ROAD:
		return false
	var spd: float = a["speed"]
	if is_car:
		spd *= 1.0 - 0.8 * sim.traffic[D.idx(to.x, to.y)]
	a["t"] = float(a["t"]) + spd * delta
	if float(a["t"]) >= 1.0:
		a["t"] = float(a["t"]) - 1.0
		var nbrs := _road_neighbors(to)
		var back := from
		if nbrs.size() > 1:
			nbrs.erase(back)
		if nbrs.is_empty():
			return false
		a["from"] = to
		a["to"] = nbrs[randi() % nbrs.size()]
		from = a["from"]
		to = a["to"]
	var dir := Vector3(to.x - from.x, 0, to.y - from.y)
	var right := Vector3(-dir.z, 0, dir.x)
	var p := Vector3(from.x, 0, from.y).lerp(Vector3(to.x, 0, to.y), float(a["t"])) + right * float(a["side"])
	var node: Node3D = a["node"]
	node.position = Vector3(p.x, 0.05 if is_car else 0.06 + absf(sin(_time * 9.0 + p.x)) * 0.015, p.z)
	if dir.length_squared() > 0.0:
		node.rotation.y = lerp_angle(node.rotation.y, atan2(dir.x, dir.z), minf(1.0, delta * 10.0))
	return true


func _update_population(delta: float) -> void:
	var roads := int(sim.stats.get("roads", 0))
	var pop := int(sim.stats.get("population", 0))
	var want_cars := clampi(int(float(roads) * 0.08 + float(pop) / 70.0), 4, 70)
	var want_peds := clampi(pop / 45, 0, 60)
	if sim.work_based():
		# Named residents make the real trips; ambient traffic only fills in for everyone else.
		want_cars = clampi(int(float(roads) * float(sim.stats.get("traffic", 0.0)) * 0.12), 2, 30)
		want_peds = clampi(pop / 200, 0, 15)
	if _cars.size() < want_cars and randf() < 0.3:
		_spawn_agent(true)
	if _peds.size() < want_peds and randf() < 0.3:
		_spawn_agent(false)
	for list: Array in [_cars, _peds]:
		var is_car := list == _cars
		var keep: Array[Dictionary] = []
		var limit := want_cars if is_car else want_peds
		for a: Dictionary in list:
			if keep.size() < limit and _advance_agent(a, delta, is_car):
				keep.append(a)
			else:
				(a["node"] as Node3D).queue_free()
		list.clear()
		list.append_array(keep)


# ------------------------------------------------------------------ frame loop & input

func _process(delta: float) -> void:
	if sim == null:
		return
	_time += delta
	var t := Time.get_ticks_usec()
	if not _dirty_tree_chunks.is_empty():
		for c: Vector3i in _dirty_tree_chunks.keys():
			if c.z in _tree_layers():
				_refresh_tree_chunk(c)
		_dirty_tree_chunks.clear()
	t = _section("trees", t)
	if not _warming.is_empty():
		_poll_warming()
	t = _section("warming", t)
	if not fp_mode:
		_update_population(delta)
	_status_timer += delta
	if _status_timer > 0.6:
		_status_timer = 0.0
		_refresh_status()
	t = _section("status", t)
	var pulse := 0.85 + 0.15 * sin(_time * 4.0)
	_power_icons.scale = Vector3.ONE * pulse
	_power_icons.position = Vector3((1.0 - pulse) * 15.5, 0, (1.0 - pulse) * 15.5)
	_water_icons.scale = _power_icons.scale
	_water_icons.position = _power_icons.position
	for av: Dictionary in _avatars:
		var root: Node3D = av["root"]
		var target: Vector3 = av["target"]
		var to := target - root.position
		to.y = 0.0
		if to.length() > 0.05:
			var stp := minf(to.length(), delta * 3.0)
			root.position += to.normalized() * stp
			root.rotation.y = lerp_angle(root.rotation.y, atan2(to.x, to.z), minf(1.0, delta * 8.0))
		root.position.y = 0.05 + sin(_time * 3.0 + root.position.x) * 0.03
		av["bubble_t"] = float(av["bubble_t"]) - delta
		if float(av["bubble_t"]) <= 0.0:
			(av["bubble"] as Label3D).visible = false
	var keep_b: Array[Dictionary] = []
	for b in _bubbles:
		b["t"] = float(b["t"]) - delta
		var node: Label3D = b["node"]
		if float(b["t"]) <= 0.0:
			node.queue_free()
		else:
			node.modulate.a = clampf(float(b["t"]) / 2.0, 0.0, 1.0)
			keep_b.append(b)
	_bubbles = keep_b
	for id: int in _event_nodes.keys():
		var root2: Node3D = _event_nodes[id]
		for c in root2.get_children():
			if c.has_meta("pulse"):
				var s := 1.0 + 0.06 * sin(_time * 5.0)
				(c as Node3D).scale = Vector3(s, 0.15, s)
			if c.has_meta("drift"):
				(c as Node3D).position.y = 1.3 + sin(_time * 0.8 + float(c.get_meta("drift"))) * 0.3
		if str(root2.get_meta("type", "")) == "tornado":
			root2.rotation.y += delta * 6.0
			var path: Array = root2.get_meta("path", [])
			if not path.is_empty():
				var idx := int(_time * 1.5) % path.size()
				var ti := int(path[idx])
				root2.position = root2.position.lerp(Vector3(D.tx(ti), 0.05, D.ty(ti)), minf(1.0, delta * 3.0))
	t = _section("bubbles_events", t)
	_animate_parts(delta)
	t = _section("parts", t)
	_animate_sites(delta)
	t = _section("sites", t)
	if not _flicker_lights.is_empty():
		var live: Array[OmniLight3D] = []
		for l: Variant in _flicker_lights:
			if is_instance_valid(l):
				(l as OmniLight3D).light_energy = 2.0 + randf() * 1.2
				live.append(l)
		_flicker_lights = live
	if fp_mode and not _queue.is_empty():
		_process_queue(delta)
	_section("queue", t)
	if not fp_mode:
		if _shake > 0.0 and camera != null:
			_shake = maxf(0.0, _shake - delta)
			camera.h_offset = randf_range(-0.25, 0.25) * _shake
			camera.v_offset = randf_range(-0.25, 0.25) * _shake
		elif camera != null:
			camera.h_offset = 0.0
			camera.v_offset = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if fp_mode or _cursor == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressed = true
				_press_pos = mb.position
			elif _pressed:
				_pressed = false
				if mb.position.distance_to(_press_pos) < 6.0:
					var rid := avatars.pick(mb.position) if avatars != null else ""
					if not rid.is_empty():
						avatars.select(rid)
						resident_clicked.emit(rid)
						return
					var t := screen_to_tile(mb.position)
					if t != D.NO_TILE:
						tile_clicked.emit(t.x, t.y)
	elif event is InputEventMouseMotion:
		var t2 := screen_to_tile((event as InputEventMouseMotion).position)
		if t2 != D.NO_TILE:
			_cursor.visible = true
			_cursor.position = Vector3(t2.x, 0.09, t2.y)
			tile_hovered.emit(t2.x, t2.y)
		else:
			_cursor.visible = false


func screen_to_tile(screen_pos: Vector2) -> Vector2i:
	if camera == null:
		return D.NO_TILE
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.0001:
		return D.NO_TILE
	var t := -origin.y / dir.y
	if t < 0.0:
		return D.NO_TILE
	var hit := origin + dir * t
	var x := int(round(hit.x))
	var y := int(round(hit.z))
	if not D.in_bounds(x, y):
		return D.NO_TILE
	return Vector2i(x, y)


func tile_world(x: int, y: int) -> Vector3:
	return Vector3(x, 0, y)
