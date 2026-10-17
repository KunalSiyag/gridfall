class_name GridFallWorld
extends Node3D
## Living SimCity-style 3D establishment for GridFall:
## - 19x19 city grid + 3-tile forested border with real Kenney asphalt roads,
##   intersections, streetlights, fountains, parks, and intersection planters.
## - 14 autonomous cars driving the road loops (obeying lanes, following gaps,
##   and traffic signal pylons; slowing down during traffic jams).
## - 18 walking citizens + a pet dog strolling the sidewalks.
## - 6 Civic Utility Landmarks (Substation, Battery Depot, Council Dome,
##   Compute Exchange, Pod Shelter, Bio-Sewage Treatment Plant).
## - Dynamic Agent District Construction: spawns & animates up to 40 agent-built
##   structures (R&D Labs, Sewage Plants, Solar Arrays, Transit Plazas, Parks,
##   Offices, Data Centers, Venture Towers) with territory borders & flags.
## - 3D SimCity Crisis Hazards: bubbling green Sewage Main Bursts, pulsing
##   Traffic Gridlock beacons, Substation Blackout arcs, and Toxic Smog clouds.

const WORLD_SIZE := 19
const BORDER := 3
const ROAD_EVERY := 6

const LANDMARK_MODELS := {
	"substation": "res://models/blender/landmark_substation.glb",
	"battery_depot": "res://models/blender/landmark_battery_depot.glb",
	"council_dome": "res://models/blender/landmark_council_dome.glb",
	"compute_exchange": "res://models/blender/landmark_compute_exchange.glb",
	"pod_shelter": "res://models/blender/landmark_pod_shelter.glb",
	"sewage_plant": "res://models/blender/landmark_sewage_plant.glb",
}

const AGENT_BUILDING_MODELS := {
	"office": "res://models/blender/office.glb",
	"sewage_plant": "res://models/blender/landmark_sewage_plant.glb",
	"transit_plaza": "res://models/blender/transit_plaza.glb",
	"solar_array": "res://models/blender/solar_array.glb",
	"park": "res://models/blender/park.glb",
	"rd_lab": "res://models/blender/rd_lab.glb",
	"data_center": "res://models/blender/data_center.glb",
	"venture_tower": "res://models/blender/venture_tower.glb",
	"logistics_depot": "res://models/blender/logistics_depot.glb",
	"media_studio": "res://models/blender/media_studio.glb",
	"exchange_hub": "res://models/blender/exchange_hub.glb",
	"garage": "res://models/blender/garage.glb",
	"pod_shelter": "res://models/blender/landmark_pod_shelter.glb",
}

const CAR_SCENES: Array[String] = [
	"res://models/cars/sedan.glb",
	"res://models/cars/taxi.glb",
	"res://models/cars/van.glb",
	"res://models/cars/suv.glb",
	"res://models/cars/hatchback-sports.glb",
	"res://models/cars/police.glb",
]

const FILLER_MODELS: Array[String] = [
	"res://models/building-small-a.glb",
	"res://models/building-small-b.glb",
	"res://models/building-small-c.glb",
	"res://models/building-small-d.glb",
	"res://models/building-garage.glb",
	"res://models/blender/office.glb",
	"res://models/blender/garage.glb",
	"res://models/blender/park.glb",
]

const RESIDENT_MODEL := "res://models/blender/resident_bot.glb"
const FLAG_MODEL := "res://models/blender/founder_flag.glb"
const PLANTER_MODEL := "res://models/blender/planter.glb"
const PYLON_MODEL := "res://models/blender/signal_pylon.glb"

const SHIRTS: Array[Color] = [
	Color(0.95, 0.35, 0.30),
	Color(0.30, 0.55, 0.95),
	Color(0.35, 0.80, 0.45),
	Color(0.98, 0.80, 0.25),
	Color(0.70, 0.45, 0.90),
	Color(0.95, 0.55, 0.25),
	Color(0.40, 0.85, 0.85),
	Color(0.90, 0.90, 0.92),
]
const SKINS: Array[Color] = [
	Color(0.98, 0.82, 0.66),
	Color(0.87, 0.64, 0.47),
	Color(0.65, 0.45, 0.32),
	Color(0.45, 0.31, 0.23),
]

var _road_shader_mat: ShaderMaterial
var _building_shader_mat: ShaderMaterial

var _terrain_root: Node3D
var _landmarks_root: Node3D
var _agent_buildings_root: Node3D
var _filler_root: Node3D
var _hazards_root: Node3D
var _traffic_root: Node3D
var _pedestrians_root: Node3D
var _residents_root: Node3D
var _beams_root: Node3D

var _landmark_nodes: Dictionary = {}        ## key -> Node3D
var _landmark_positions: Dictionary = {}    ## key -> Vector3
var _agent_building_nodes: Dictionary = {}  ## "x,z" -> Node3D
var _filler_by_coord: Dictionary = {}       ## "x,z" -> Node3D

var _resident_nodes: Dictionary = {}        ## id -> Node3D
var _resident_targets: Dictionary = {}      ## id -> Vector3
var _resident_colors: Dictionary = {}       ## id -> Color
var _resident_badges: Dictionary = {}       ## id -> Label3D
var _beam_nodes: Dictionary = {}            ## id -> MeshInstance3D

# Traffic & Pedestrians state
var _cars: Array[Dictionary] = []
var _walkers: Array[Dictionary] = []
var _beacon_meshes: Array[MeshInstance3D] = []
var _x_green: bool = true
var _signal_timer: float = 0.0
var _traffic_congested: bool = false
var _traffic_speed_mult: float = 1.0

# Hazard VFX state
var _hazard_vfx_nodes: Array[Dictionary] = []
var _custom_hazards: Array[Dictionary] = []

var _blackout_intensity: float = 0.0
var _target_blackout: float = 0.0
var _water_sewage_pct: float = 92.0
var _sanitation_pct: float = 92.0
var _time: float = 0.0
var _built_done: bool = false


func build_city(episode_meta: Dictionary) -> void:
	if _built_done:
		return
	_built_done = true
	_setup_shaders()

	_terrain_root = Node3D.new()
	_terrain_root.name = "Terrain"
	add_child(_terrain_root)

	_filler_root = Node3D.new()
	_filler_root.name = "FillerBuildings"
	add_child(_filler_root)

	_landmarks_root = Node3D.new()
	_landmarks_root.name = "Landmarks"
	add_child(_landmarks_root)

	_agent_buildings_root = Node3D.new()
	_agent_buildings_root.name = "AgentBuildings"
	add_child(_agent_buildings_root)

	_hazards_root = Node3D.new()
	_hazards_root.name = "Hazards"
	add_child(_hazards_root)

	_traffic_root = Node3D.new()
	_traffic_root.name = "Traffic"
	add_child(_traffic_root)

	_pedestrians_root = Node3D.new()
	_pedestrians_root.name = "Pedestrians"
	add_child(_pedestrians_root)

	_beams_root = Node3D.new()
	_beams_root.name = "EnergyBeams"
	add_child(_beams_root)

	_residents_root = Node3D.new()
	_residents_root.name = "Residents"
	add_child(_residents_root)

	var landmarks_cfg: Dictionary = episode_meta.get("landmarks", {})
	var residents_cfg: Array = episode_meta.get("residents", [])

	# Collect reserved coordinates (landmarks + all scheduled agent builds)
	var landmark_coords: Dictionary = {}
	for lm_key in landmarks_cfg.keys():
		var grid: Array = landmarks_cfg[lm_key].get("grid", [9, 9])
		var coord_key := "%d,%d" % [int(grid[0]), int(grid[1])]
		landmark_coords[coord_key] = lm_key
		_landmark_positions[lm_key] = Vector3(float(grid[0]), 0.0, float(grid[1]))

	var scheduled_agent_coords: Dictionary = {}
	for r in residents_cfg:
		for b in r.get("build_sequence", []):
			var c: Array = b.get("coord", [2, 2])
			scheduled_agent_coords["%d,%d" % [int(c[0]), int(c[1])]] = true

	_build_ground_and_roads(landmark_coords, scheduled_agent_coords)
	_spawn_landmarks(landmarks_cfg)
	_spawn_traffic()
	_spawn_pedestrians()
	_spawn_residents(residents_cfg)


func _setup_shaders() -> void:
	_road_shader_mat = ShaderMaterial.new()
	_road_shader_mat.shader = load("res://shaders/road_conduit.gdshader") as Shader
	_road_shader_mat.set_shader_parameter("blackout_intensity", 0.0)

	_building_shader_mat = ShaderMaterial.new()
	_building_shader_mat.shader = load("res://shaders/building_power.gdshader") as Shader
	_building_shader_mat.set_shader_parameter("blackout_intensity", 0.0)


func _build_ground_and_roads(landmark_coords: Dictionary, scheduled_agent_coords: Dictionary) -> void:
	var grass_scn := load("res://models/grass.glb") as PackedScene
	var pave_scn := load("res://models/pavement.glb") as PackedScene
	var road_s_scn := load("res://models/road-straight.glb") as PackedScene
	var road_i_scn := load("res://models/road-intersection.glb") as PackedScene
	var road_l_scn := load("res://models/road-straight-lightposts.glb") as PackedScene
	var trees_scn := load("res://models/grass-trees.glb") as PackedScene
	var trees_tall_scn := load("res://models/grass-trees-tall.glb") as PackedScene
	var fountain_scn := load("res://models/pavement-fountain.glb") as PackedScene
	var planter_scn := load(PLANTER_MODEL) as PackedScene

	# Subtle glowing grid conduit strip running along road shoulders
	var conduit_mesh := PlaneMesh.new()
	conduit_mesh.size = Vector2(0.98, 0.98)

	# Underlying terrain table
	var table_mesh := BoxMesh.new()
	table_mesh.size = Vector3(float(WORLD_SIZE + BORDER * 2 + 2), 0.5, float(WORLD_SIZE + BORDER * 2 + 2))
	var table_mat := StandardMaterial3D.new()
	table_mat.albedo_color = Color(0.14, 0.19, 0.24)
	table_mat.roughness = 0.95
	var table_inst := MeshInstance3D.new()
	table_inst.mesh = table_mesh
	table_inst.material_override = table_mat
	table_inst.position = Vector3(9.0, -0.27, 9.0)
	_terrain_root.add_child(table_inst)

	for gx in range(-BORDER, WORLD_SIZE + BORDER):
		for gz in range(-BORDER, WORLD_SIZE + BORDER):
			var in_city := gx >= 0 and gx < WORLD_SIZE and gz >= 0 and gz < WORLD_SIZE
			if not in_city:
				var h := absi(gx * 13 + gz * 7)
				var b_scn := trees_scn if h % 3 == 0 else (trees_tall_scn if h % 5 == 0 else grass_scn)
				if b_scn:
					var b_node := b_scn.instantiate() as Node3D
					b_node.position = Vector3(float(gx), 0.0, float(gz))
					_terrain_root.add_child(b_node)
				continue

			var is_rx := (gx % ROAD_EVERY == 0)
			var is_rz := (gz % ROAD_EVERY == 0)
			var is_road := is_rx or is_rz
			var coord_key := "%d,%d" % [gx, gz]

			if is_road:
				var r_scn: PackedScene = road_s_scn
				var yaw_deg := 0.0
				if is_rx and is_rz:
					r_scn = road_i_scn
				elif is_rx:
					r_scn = road_l_scn if (gz % 2 == 0) else road_s_scn
					yaw_deg = 0.0
				else:
					r_scn = road_l_scn if (gx % 2 == 0) else road_s_scn
					yaw_deg = 90.0
				if r_scn:
					var r_node := r_scn.instantiate() as Node3D
					r_node.position = Vector3(float(gx), 0.0, float(gz))
					r_node.rotation_degrees.y = yaw_deg
					_terrain_root.add_child(r_node)

				# Subtle glowing power trace under road edges so blackout shader is visible
				var trace := MeshInstance3D.new()
				trace.mesh = conduit_mesh
				trace.material_override = _road_shader_mat
				trace.position = Vector3(float(gx), 0.004, float(gz))
				_terrain_root.add_child(trace)
			else:
				var hash_v := absi(gx * 31 + gz * 17)
				var ground_scn: PackedScene = pave_scn
				if not landmark_coords.has(coord_key) and not scheduled_agent_coords.has(coord_key):
					if hash_v % 7 == 0:
						ground_scn = trees_scn
					elif hash_v % 13 == 0:
						ground_scn = fountain_scn
					elif hash_v % 5 == 0:
						ground_scn = grass_scn
				if ground_scn:
					var g_node := ground_scn.instantiate() as Node3D
					g_node.position = Vector3(float(gx), 0.0, float(gz))
					_terrain_root.add_child(g_node)

				# Ambient background city buildings on non-reserved plots
				if not landmark_coords.has(coord_key) and not scheduled_agent_coords.has(coord_key):
					if hash_v % 4 == 0:
						var f_path: String = FILLER_MODELS[hash_v % FILLER_MODELS.size()]
						var f_scn := load(f_path) as PackedScene
						if f_scn:
							var f_node := f_scn.instantiate() as Node3D
							f_node.position = Vector3(float(gx), 0.0, float(gz))
							f_node.scale = Vector3.ONE * 0.86
							f_node.rotation_degrees.y = float((hash_v % 4) * 90)
							_filler_root.add_child(f_node)
							_filler_by_coord[coord_key] = f_node

	# Street corner planters at every intersection
	if planter_scn:
		for ix in [0, 6, 12, 18]:
			for iz in [0, 6, 12, 18]:
				var prop := planter_scn.instantiate() as Node3D
				if prop:
					prop.position = Vector3(float(ix) - 0.36, 0.0, float(iz) - 0.36)
					_terrain_root.add_child(prop)


func _spawn_landmarks(landmarks_cfg: Dictionary) -> void:
	for lm_key in landmarks_cfg.keys():
		var info: Dictionary = landmarks_cfg[lm_key]
		var grid: Array = info.get("grid", [9, 9])
		var pos := Vector3(float(grid[0]), 0.0, float(grid[1]))
		_landmark_positions[lm_key] = pos

		var model_path: String = LANDMARK_MODELS.get(lm_key, "")
		if model_path.is_empty():
			continue
		var packed := load(model_path) as PackedScene
		if packed == null:
			continue
		var node := packed.instantiate() as Node3D
		node.name = "Landmark_" + lm_key
		node.position = pos
		_landmarks_root.add_child(node)
		_landmark_nodes[lm_key] = node

		# Glowing civic ring around landmark
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = 0.50
		ring_mesh.outer_radius = 0.56
		var ring_inst := MeshInstance3D.new()
		ring_inst.mesh = ring_mesh
		ring_inst.material_override = _building_shader_mat
		ring_inst.position = Vector3(0.0, 0.03, 0.0)
		node.add_child(ring_inst)

		# 3D billboard title above landmark
		var lbl := Label3D.new()
		lbl.text = "🏛️ " + str(info.get("label", lm_key))
		lbl.font_size = 30
		lbl.outline_size = 10
		lbl.pixel_size = 0.0042
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.modulate = Color(0.88, 0.96, 1.0, 0.96)
		lbl.position = Vector3(0.0, 1.42, 0.0)
		node.add_child(lbl)


## Spawns 14 autonomous cars driving along the 4 road avenues and stopping at intersections.
func _spawn_traffic() -> void:
	var loops: Array[PackedVector3Array] = [
		_rect_loop(0, 0, 18, 18),
		_rect_loop(0, 6, 18, 12),
		_rect_loop(6, 0, 12, 18),
		_rect_loop(6, 6, 12, 12),
	]
	var car_count := 14
	for i in range(car_count):
		var scn := load(CAR_SCENES[i % CAR_SCENES.size()]) as PackedScene
		if scn == null:
			continue
		var node := scn.instantiate() as Node3D
		node.scale = Vector3.ONE * 0.54
		_traffic_root.add_child(node)
		var loop: PackedVector3Array = loops[i % loops.size()]
		var total_len := _loop_len(loop)
		var prog := fmod(float(i) * (total_len / float(car_count)) * 1.7, leg_len(loop, 0))
		var car_dict := {
			"node": node,
			"loop": loop,
			"segment": i % loop.size(),
			"progress": prog,
			"cruise": 2.35 + float((i * 19) % 5) * 0.12,
			"speed": 1.8,
			"lane": 0.16,
			"off": Vector3.ZERO,
		}
		_cars.append(car_dict)
		_place_on_loop(car_dict, 0.06, 1.0)

	# Intersection traffic signal pylons
	var pylon_scn := load(PYLON_MODEL) as PackedScene
	var beacon_sphere := SphereMesh.new()
	beacon_sphere.radius = 0.06
	beacon_sphere.height = 0.12
	for ix in [0, 6, 12, 18]:
		for iz in [0, 6, 12, 18]:
			if pylon_scn:
				var pylon := pylon_scn.instantiate() as Node3D
				pylon.position = Vector3(float(ix) + 0.42, 0.0, float(iz) + 0.42)
				_traffic_root.add_child(pylon)
			var beacon := MeshInstance3D.new()
			beacon.mesh = beacon_sphere
			var bmat := StandardMaterial3D.new()
			bmat.albedo_color = Color(0.1, 0.95, 0.55)
			bmat.emission_enabled = true
			bmat.emission = Color(0.1, 0.95, 0.55)
			bmat.emission_energy_multiplier = 2.0
			beacon.material_override = bmat
			beacon.position = Vector3(float(ix) + 0.42, 0.62, float(iz) + 0.42)
			_traffic_root.add_child(beacon)
			_beacon_meshes.append(beacon)


## Spawns 18 walking citizens on sidewalks + a pet dog trailing walker 0.
func _spawn_pedestrians() -> void:
	var loops: Array[PackedVector3Array] = [
		_rect_loop_ccw(0, 0, 18, 18),
		_rect_loop_ccw(0, 6, 18, 12),
		_rect_loop_ccw(6, 0, 12, 18),
	]
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.065
	body_mesh.height = 0.30
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.075
	head_mesh.height = 0.15

	var walker_count := 18
	for i in range(walker_count):
		var loop: PackedVector3Array = loops[i % loops.size()]
		var root := Node3D.new()
		root.name = "Citizen_%d" % i
		_pedestrians_root.add_child(root)

		var shirt_mat := StandardMaterial3D.new()
		shirt_mat.albedo_color = SHIRTS[i % SHIRTS.size()]
		var skin_mat := StandardMaterial3D.new()
		skin_mat.albedo_color = SKINS[(i * 3) % SKINS.size()]
		var pants_mat := StandardMaterial3D.new()
		pants_mat.albedo_color = Color(0.18, 0.22, 0.30)

		var legs := MeshInstance3D.new()
		legs.mesh = body_mesh
		legs.material_override = pants_mat
		legs.position = Vector3(0.0, 0.15, 0.0)
		legs.scale = Vector3(0.82, 0.55, 0.82)
		root.add_child(legs)

		var torso := MeshInstance3D.new()
		torso.mesh = body_mesh
		torso.material_override = shirt_mat
		torso.position = Vector3(0.0, 0.33, 0.0)
		root.add_child(torso)

		var head := MeshInstance3D.new()
		head.mesh = head_mesh
		head.material_override = skin_mat
		head.position = Vector3(0.0, 0.54, 0.0)
		root.add_child(head)

		var w_dict := {
			"node": root,
			"loop": loop,
			"segment": i % loop.size(),
			"progress": float(i) * 1.9,
			"speed": 0.72 + float((i * 11) % 5) * 0.06,
			"lane": -0.35,
			"off": Vector3.ZERO,
			"phase": float(i) * 1.3,
		}
		_walkers.append(w_dict)
		_place_on_loop(w_dict, 0.0, 1.0)


func _spawn_residents(residents_cfg: Array) -> void:
	var bot_packed := load(RESIDENT_MODEL) as PackedScene
	for i in range(residents_cfg.size()):
		var r: Dictionary = residents_cfg[i]
		var rid: String = str(r.get("id", "res_%d" % i))
		var rname: String = str(r.get("name", rid))
		var rmodel: String = str(r.get("model", ""))
		var col := Color.from_string(str(r.get("color", "#00F0FF")), Color(0.0, 0.94, 1.0))
		_resident_colors[rid] = col

		var home: Array = r.get("home_plot", [9, 9])
		var start_pos := Vector3(float(home[0]), 0.04, float(home[1]))

		var agent_root := Node3D.new()
		agent_root.name = "Resident_" + rid
		agent_root.position = start_pos
		_residents_root.add_child(agent_root)
		_resident_nodes[rid] = agent_root
		_resident_targets[rid] = start_pos

		if bot_packed != null:
			var bot := bot_packed.instantiate() as Node3D
			bot.scale = Vector3.ONE * 1.18
			agent_root.add_child(bot)
			_tint_resident_bot(bot, col)

		var badge := Label3D.new()
		badge.text = "%s\n[%s]" % [rname, rmodel.get_slice("/", 1)]
		badge.font_size = 26
		badge.outline_size = 9
		badge.pixel_size = 0.0036
		badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		badge.no_depth_test = true
		badge.modulate = col.lightened(0.25)
		badge.position = Vector3(0.0, 0.95 + float(i) * 0.28, 0.0)
		agent_root.add_child(badge)
		_resident_badges[rid] = badge

		var beam_inst := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.032
		cyl.bottom_radius = 0.032
		cyl.height = 1.0
		beam_inst.mesh = cyl
		var beam_mat := StandardMaterial3D.new()
		beam_mat.albedo_color = col
		beam_mat.emission_enabled = true
		beam_mat.emission = col
		beam_mat.emission_energy_multiplier = 2.8
		beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		beam_mat.albedo_color.a = 0.82
		beam_inst.material_override = beam_mat
		beam_inst.visible = false
		_beams_root.add_child(beam_inst)
		_beam_nodes[rid] = beam_inst


func _tint_resident_bot(bot: Node3D, col: Color) -> void:
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_color = col
	glow_mat.emission_enabled = true
	glow_mat.emission = col
	glow_mat.emission_energy_multiplier = 2.8
	for part_name in ["Visor", "Halo", "Core"]:
		var found := bot.find_child(part_name, true, false)
		if found is MeshInstance3D:
			(found as MeshInstance3D).material_override = glow_mat


## Called whenever a simulation day/tick is applied.
func apply_tick_state(tick_data: Dictionary) -> void:
	_target_blackout = float(tick_data.get("blackout_intensity", 0.0))
	var vitals: Dictionary = tick_data.get("vitals", {})
	_water_sewage_pct = float(vitals.get("water_sewage_pct", 90.0))
	_sanitation_pct = float(vitals.get("sanitation_air_pct", 90.0))
	var traffic_pct := float(vitals.get("traffic_flow_pct", 85.0))
	_traffic_congested = traffic_pct < 50.0
	_traffic_speed_mult = clampf(traffic_pct / 85.0, 0.28, 1.15)
	_update_traffic_beacons()

	var current_tick := int(tick_data.get("tick", 1))
	_sync_agent_buildings(tick_data.get("constructed_buildings", []), current_tick)

	var all_hazards: Array = []
	for h in tick_data.get("hazards", []):
		all_hazards.append(h)
	for ch in _custom_hazards:
		all_hazards.append(ch)
	_sync_hazards(all_hazards)

	var actions: Array = tick_data.get("actions", [])
	var slot_Wait: Dictionary = {}

	for i in range(actions.size()):
		var act: Dictionary = actions[i]
		var rid: String = str(act.get("resident_id", ""))
		var lm_key: String = str(act.get("target_landmark", "council_dome"))
		var action_code: String = str(act.get("action", "SHARE_POWER"))
		var rname: String = str(act.get("resident_name", rid))
		var built_today: Dictionary = act.get("built_today", {})

		var slot: int = int(slot_Wait.get(lm_key, 0))
		slot_Wait[lm_key] = slot + 1

		# Agents move either toward their newly constructed building or the crisis landmark
		var base_pos: Vector3 = _landmark_positions.get(lm_key, Vector3(9.0, 0.04, 9.0))
		var angle := float(slot) * (TAU / 5.0) + float(i) * 0.55
		var offset := Vector3(cos(angle) * 1.32, 0.0, sin(angle) * 1.32)
		_resident_targets[rid] = Vector3(base_pos.x + offset.x, 0.04, base_pos.z + offset.z)

		if _resident_badges.has(rid):
			var badge: Label3D = _resident_badges[rid]
			var b_label := str(built_today.get("label", ""))
			if not b_label.is_empty():
				badge.text = "%s\n[%s · 🏗️ %s]" % [rname, action_code, b_label]
			else:
				badge.text = "%s\n[%s]" % [rname, action_code]

		if _beam_nodes.has(rid):
			var beam: MeshInstance3D = _beam_nodes[rid]
			var bmat := beam.material_override as StandardMaterial3D
			if action_code == "HOARD_BATTERY":
				bmat.albedo_color = Color(1.0, 0.18, 0.33, 0.88)
				bmat.emission = Color(1.0, 0.18, 0.33)
			else:
				var c: Color = _resident_colors.get(rid, Color(0.0, 0.94, 1.0))
				bmat.albedo_color = Color(c.r, c.g, c.b, 0.82)
				bmat.emission = c
			beam.visible = true


## Synchronizes all agent-constructed buildings up to the current day, with pop-in scale for new builds.
func _sync_agent_buildings(constructed: Array, current_tick: int) -> void:
	for child in _agent_buildings_root.get_children():
		child.queue_free()
	_agent_building_nodes.clear()

	var flag_scn := load(FLAG_MODEL) as PackedScene
	var pad_mesh := BoxMesh.new()
	pad_mesh.size = Vector3(0.94, 0.05, 0.94)

	for b in constructed:
		var c: Array = b.get("coord", [2, 2])
		var gx := int(c[0])
		var gz := int(c[1])
		var coord_key := "%d,%d" % [gx, gz]
		var b_type := str(b.get("building", "office"))
		var b_label := str(b.get("label", b_type))
		var owner_name := str(b.get("owner_name", "Agent"))
		var col := Color.from_string(str(b.get("color", "#00F0FF")), Color(0.0, 0.94, 1.0))
		var tick_built := int(b.get("tick_built", 1))

		var holder := Node3D.new()
		holder.position = Vector3(float(gx), 0.0, float(gz))
		_agent_buildings_root.add_child(holder)
		_agent_building_nodes[coord_key] = holder

		# Colored territory foundation pad
		var pad := MeshInstance3D.new()
		pad.mesh = pad_mesh
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = col.darkened(0.35)
		pmat.emission_enabled = true
		pmat.emission = col
		pmat.emission_energy_multiplier = 0.65
		pad.material_override = pmat
		pad.position = Vector3(0.0, 0.025, 0.0)
		holder.add_child(pad)

		# 3D building mesh
		var model_path: String = AGENT_BUILDING_MODELS.get(b_type, "res://models/blender/office.glb")
		var scn := load(model_path) as PackedScene
		if scn:
			var b_node := scn.instantiate() as Node3D
			holder.add_child(b_node)
			if tick_built == current_tick:
				b_node.scale = Vector3.ONE * 0.2
				var tw := create_tween()
				tw.tween_property(b_node, "scale", Vector3.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

		# Owner flag banner on corner
		if flag_scn:
			var flag := flag_scn.instantiate() as Node3D
			flag.position = Vector3(0.36, 0.04, -0.36)
			var banner := flag.find_child("Banner", true, false) as MeshInstance3D
			if banner:
				var fmat := StandardMaterial3D.new()
				fmat.albedo_color = col
				fmat.emission_enabled = true
				fmat.emission = col
				fmat.emission_energy_multiplier = 1.2
				banner.material_override = fmat
			holder.add_child(flag)

		# Show floating construction badge on buildings built this day
		if tick_built == current_tick:
			var tag := Label3D.new()
			tag.text = "🏗️ %s\n(%s)" % [b_label, owner_name]
			tag.font_size = 22
			tag.outline_size = 8
			tag.pixel_size = 0.0034
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.no_depth_test = true
			tag.modulate = col.lightened(0.35)
			tag.position = Vector3(0.0, 1.35, 0.0)
			holder.add_child(tag)


## Spawns 3D SimCity hazard VFX (bubbling green sewage geysers, traffic jam beacons, blackout arcs, smog clouds).
func _sync_hazards(hazards: Array) -> void:
	for child in _hazards_root.get_children():
		child.queue_free()
	_hazard_vfx_nodes.clear()

	for h in hazards:
		var htype := str(h.get("type", "sewage_burst"))
		var hlabel := str(h.get("label", "Civic Emergency"))
		var c: Array = h.get("coord", [9, 15])
		var pos := Vector3(float(c[0]), 0.05, float(c[1]))

		var root := Node3D.new()
		root.position = pos
		_hazards_root.add_child(root)

		var col := Color(0.25, 0.95, 0.30)
		if htype == "sewage_burst":
			col = Color(0.38, 0.88, 0.18) # Toxic bio-green sewage burst
			# Expanding toxic puddle + 4 bubbling geyser spheres
			var puddle := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.85
			cyl.bottom_radius = 0.90
			cyl.height = 0.04
			puddle.mesh = cyl
			var pmat := StandardMaterial3D.new()
			pmat.albedo_color = Color(0.24, 0.58, 0.14, 0.85)
			pmat.emission_enabled = true
			pmat.emission = Color(0.32, 0.85, 0.16)
			pmat.emission_energy_multiplier = 1.6
			pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			puddle.material_override = pmat
			root.add_child(puddle)
		elif htype == "traffic_jam":
			col = Color(1.0, 0.58, 0.08) # Amber traffic alert
		elif htype == "grid_blackout":
			col = Color(1.0, 0.18, 0.33) # Crimson blackout overload
		else:
			col = Color(0.68, 0.62, 0.38) # Smog cloud

		var plumes: Array[MeshInstance3D] = []
		for p_idx in range(4):
			var sp := MeshInstance3D.new()
			var sm := SphereMesh.new()
			var rad := 0.26 if htype == "smog_spike" else 0.14
			sm.radius = rad
			sm.height = rad * 2.0
			sp.mesh = sm
			var smat := StandardMaterial3D.new()
			smat.albedo_color = Color(col.r, col.g, col.b, 0.78)
			smat.emission_enabled = true
			smat.emission = col
			smat.emission_energy_multiplier = 2.2
			smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			sp.material_override = smat
			var ang := float(p_idx) * (TAU / 4.0)
			sp.position = Vector3(cos(ang) * 0.25, 0.25 + float(p_idx) * 0.18, sin(ang) * 0.25)
			root.add_child(sp)
			plumes.append(sp)

		var lbl := Label3D.new()
		lbl.text = "⚠️ " + hlabel
		lbl.font_size = 28
		lbl.outline_size = 10
		lbl.pixel_size = 0.0040
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.modulate = col.lightened(0.25)
		lbl.position = Vector3(0.0, 1.75, 0.0)
		root.add_child(lbl)

		_hazard_vfx_nodes.append({
			"root": root,
			"type": htype,
			"plumes": plumes,
		})


## Allows the user to interactively trigger a SimCity emergency from the HUD at any time!
func trigger_interactive_problem(problem_kind: String) -> Dictionary:
	_custom_hazards.clear()
	var info := {}
	match problem_kind:
		"sewage":
			info = {
				"type": "sewage_burst",
				"label": "🚰 LIVE: Sewage Main Rupture!",
				"coord": [9, 15],
				"focus": Vector3(9.0, 0.0, 15.0),
				"headline": "🚰 EMERGENCY TRIGGERED: Sewage Main Burst at Bio-Sewage Plant [9, 15]!",
			}
			_custom_hazards.append(info)
			_water_sewage_pct = 22.0
		"traffic":
			info = {
				"type": "traffic_jam",
				"label": "🚗 LIVE: 6th Ave Commuter Gridlock!",
				"coord": [6, 6],
				"focus": Vector3(6.0, 0.0, 6.0),
				"headline": "🚗 EMERGENCY TRIGGERED: Severe Commuter Gridlock at Central Intersection [6, 6]!",
			}
			_custom_hazards.append(info)
			_traffic_congested = true
			_traffic_speed_mult = 0.25
			_update_traffic_beacons()
		"blackout":
			info = {
				"type": "grid_blackout",
				"label": "⚡ LIVE: Transformer Overload!",
				"coord": [3, 3],
				"focus": Vector3(3.0, 0.0, 3.0),
				"headline": "⚡ EMERGENCY TRIGGERED: Stage-3 Substation Blackout at [3, 3]!",
			}
			_custom_hazards.append(info)
			_target_blackout = 0.95
		"smog":
			info = {
				"type": "smog_spike",
				"label": "🌫️ LIVE: Industrial Diesel Smog!",
				"coord": [14, 10],
				"focus": Vector3(14.0, 0.0, 10.0),
				"headline": "🌫️ EMERGENCY TRIGGERED: Toxic Diesel Smog Cloud over East Strip [14, 10]!",
			}
			_custom_hazards.append(info)
			_sanitation_pct = 25.0
		"clear":
			_target_blackout = 0.0
			_traffic_congested = false
			_traffic_speed_mult = 1.0
			_water_sewage_pct = 95.0
			_sanitation_pct = 95.0
			_update_traffic_beacons()
			info = {
				"focus": Vector3(9.0, 0.0, 9.0),
				"headline": "✅ All Municipal Systems Restored to Nominal Operation!",
			}
	_sync_hazards(_custom_hazards)
	return info


func _update_traffic_beacons() -> void:
	var col := Color(1.0, 0.22, 0.28) if _traffic_congested else (Color(0.10, 0.95, 0.55) if _x_green else Color(0.0, 0.82, 1.0))
	for b in _beacon_meshes:
		var mat := b.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = col
			mat.emission = col


func _process(delta: float) -> void:
	_time += delta
	_blackout_intensity = move_toward(_blackout_intensity, _target_blackout, delta * 0.85)
	if _road_shader_mat:
		_road_shader_mat.set_shader_parameter("blackout_intensity", _blackout_intensity)
	if _building_shader_mat:
		_building_shader_mat.set_shader_parameter("blackout_intensity", _blackout_intensity)

	# Traffic signal timer
	_signal_timer += delta
	if _signal_timer >= 6.5:
		_signal_timer = 0.0
		_x_green = not _x_green
		_update_traffic_beacons()

	# Drive autonomous cars
	for car in _cars:
		_advance_car(car, delta)

	# Walk autonomous citizens
	for w in _walkers:
		_advance_walker(w, delta)

	# Animate 3D hazard plumes (sewage bubbles, smog clouds, blackout arcs)
	for h_idx in range(_hazard_vfx_nodes.size()):
		var h: Dictionary = _hazard_vfx_nodes[h_idx]
		var plumes: Array = h.get("plumes", [])
		var htype := str(h.get("type", "sewage_burst"))
		for p_i in range(plumes.size()):
			var sp: MeshInstance3D = plumes[p_i]
			if not is_instance_valid(sp):
				continue
			var phase := _time * 3.8 + float(p_i) * 1.4
			if htype == "sewage_burst":
				sp.position.y = 0.18 + absf(sin(phase)) * 0.55
				var s := 0.85 + 0.35 * sin(phase * 1.3)
				sp.scale = Vector3(s, s, s)
			elif htype == "smog_spike":
				sp.position.y = 0.75 + sin(phase * 0.6) * 0.18
				var s2 := 1.15 + 0.25 * sin(phase * 0.8)
				sp.scale = Vector3(s2, s2 * 0.7, s2)
			else:
				sp.position.y = 0.35 + absf(cos(phase * 1.5)) * 0.45

	# Move AI Mayor robots + update energy beams
	for rid in _resident_nodes.keys():
		var node: Node3D = _resident_nodes[rid]
		var target: Vector3 = _resident_targets.get(rid, node.position)
		var to_target := target - node.position
		to_target.y = 0.0
		var dist := to_target.length()
		if dist > 0.03:
			var step := minf(dist, delta * 4.2)
			var dir := to_target / dist
			node.position += dir * step
			node.rotation.y = lerp_angle(node.rotation.y, atan2(-dir.x, -dir.z), minf(1.0, delta * 8.0))
		node.position.y = 0.04 + sin(_time * 4.2 + float(rid.hash() % 10)) * 0.03

		if _beam_nodes.has(rid):
			var beam: MeshInstance3D = _beam_nodes[rid]
			if beam.visible:
				var start_p := node.position + Vector3(0.0, 0.42, 0.0)
				var end_p := target + Vector3(0.0, 0.48, 0.0)
				var diff := end_p - start_p
				var len_b := diff.length()
				if len_b > 0.15:
					beam.position = (start_p + end_p) * 0.5
					beam.scale = Vector3(1.0, len_b, 1.0)
					var up := diff.normalized()
					var axis := Vector3.UP.cross(up)
					if axis.length_squared() > 0.0001:
						beam.transform.basis = Basis(axis.normalized(), Vector3.UP.angle_to(up)).scaled(Vector3(1.0, len_b, 1.0))


func _advance_car(car: Dictionary, delta: float) -> void:
	var loop: PackedVector3Array = car["loop"]
	var seg: int = int(car["segment"])
	var a: Vector3 = loop[seg % loop.size()]
	var b: Vector3 = loop[(seg + 1) % loop.size()]
	var leg := a.distance_to(b)
	if leg < 0.001:
		return
	var dir := (b - a) / leg
	var desired: float = float(car["cruise"]) * _traffic_speed_mult

	# Slow down for car ahead in same lane
	var node: Node3D = car["node"]
	for other in _cars:
		if other == car:
			continue
		var onode: Node3D = other["node"]
		var to_o := onode.position - node.position
		var d := to_o.length()
		if d < 1.65 and d > 0.01 and dir.dot(to_o / d) > 0.75:
			if d < 0.95:
				desired = 0.0
			else:
				desired = minf(desired, float(other["speed"]) * 0.7)

	car["speed"] = move_toward(float(car["speed"]), desired, delta * 4.5)
	var rem: float = float(car["speed"]) * delta
	while rem > 0.0:
		var left := leg - float(car["progress"])
		if rem < left:
			car["progress"] = float(car["progress"]) + rem
			rem = 0.0
		else:
			rem -= left
			seg = (seg + 1) % loop.size()
			car["segment"] = seg
			car["progress"] = 0.0
			a = loop[seg % loop.size()]
			b = loop[(seg + 1) % loop.size()]
			leg = a.distance_to(b)
			if leg < 0.001:
				break
			dir = (b - a) / leg
	_place_on_loop(car, 0.06, delta)


func _advance_walker(w: Dictionary, delta: float) -> void:
	var loop: PackedVector3Array = w["loop"]
	var seg: int = int(w["segment"])
	var a: Vector3 = loop[seg % loop.size()]
	var b: Vector3 = loop[(seg + 1) % loop.size()]
	var leg := a.distance_to(b)
	if leg < 0.001:
		return
	var rem: float = float(w["speed"]) * delta
	while rem > 0.0:
		var left := leg - float(w["progress"])
		if rem < left:
			w["progress"] = float(w["progress"]) + rem
			rem = 0.0
		else:
			rem -= left
			seg = (seg + 1) % loop.size()
			w["segment"] = seg
			w["progress"] = 0.0
			a = loop[seg % loop.size()]
			b = loop[(seg + 1) % loop.size()]
			leg = a.distance_to(b)
			if leg < 0.001:
				break
	_place_on_loop(w, 0.0, delta)
	var node: Node3D = w["node"]
	node.position.y = absf(sin(_time * 8.5 + float(w["phase"]))) * 0.025


func _place_on_loop(entity: Dictionary, y_height: float, delta: float) -> void:
	var loop: PackedVector3Array = entity["loop"]
	var node: Node3D = entity["node"]
	var seg: int = int(entity["segment"])
	var a: Vector3 = loop[seg % loop.size()]
	var b: Vector3 = loop[(seg + 1) % loop.size()]
	var leg := a.distance_to(b)
	var t := clampf(float(entity["progress"]) / maxf(leg, 0.001), 0.0, 1.0)
	var center := a.lerp(b, t)
	var dir := (b - a).normalized()
	var right := dir.cross(Vector3.UP).normalized()
	var target_off := right * float(entity["lane"])
	var off: Vector3 = entity["off"]
	entity["off"] = off.lerp(target_off, minf(delta * 6.0, 1.0))
	var cur_off: Vector3 = entity["off"]
	node.position = Vector3(center.x + cur_off.x, y_height, center.z + cur_off.z)
	if dir.length_squared() > 0.0001:
		node.rotation.y = atan2(dir.x, dir.z)


func _rect_loop(x0: int, z0: int, x1: int, z1: int) -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(float(x0), 0.0, float(z0)),
		Vector3(float(x1), 0.0, float(z0)),
		Vector3(float(x1), 0.0, float(z1)),
		Vector3(float(x0), 0.0, float(z1)),
	])


func _rect_loop_ccw(x0: int, z0: int, x1: int, z1: int) -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(float(x0), 0.0, float(z0)),
		Vector3(float(x0), 0.0, float(z1)),
		Vector3(float(x1), 0.0, float(z1)),
		Vector3(float(x1), 0.0, float(z0)),
	])


func _loop_len(loop: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(loop.size()):
		total += loop[i].distance_to(loop[(i + 1) % loop.size()])
	return total


func leg_len(loop: PackedVector3Array, seg: int) -> float:
	return maxf(0.1, loop[seg % loop.size()].distance_to(loop[(seg + 1) % loop.size()]))


func resident_position(resident_id: String) -> Vector3:
	if _resident_nodes.has(resident_id):
		return (_resident_nodes[resident_id] as Node3D).position
	return Vector3(9.0, 0.0, 9.0)


func landmark_position(landmark_key: String) -> Vector3:
	return _landmark_positions.get(landmark_key, Vector3(9.0, 0.0, 9.0))
