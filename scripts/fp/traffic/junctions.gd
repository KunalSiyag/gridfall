extends RefCounted
## Junction control (docs/fp/slices/E-traffic.md §2): 4-way traffic lights on cross tiles (N-S
## green, amber, all-red, E-W green, ...), priority to the through road on tees, pedestrian walk
## phases, and the street furniture that shows them: light poles at the four corners, pedestrian
## signals at both ends of every zebra, and stop or yield signs on tee stems. Lamp states are
## per-instance material_override swaps from shared on/off materials, never edits of a material.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const KIT := preload("res://scripts/fp/traffic/mesh_kit.gd")
const GREEN := 0
const AMBER := 1
const RED := 2
## Phase lengths, real seconds at 1x (multiplied out by sim.speed through the clock).
const T_GREEN := 12.0
const T_AMBER := 3.0
const T_ALLRED := 1.0
const CYCLE := 2.0 * (T_GREEN + T_AMBER + T_ALLRED)
## People start across a signalled zebra only this early in its walk phase, so they clear the
## carriageway before the cross traffic gets green.
const WALK_START := 4.5
## Corner poles at (±0.42, ±0.42); masts along local -X reach over the inbound lane.
const POLE_AT := 0.42
const MAST := 5.5 * WS.M
## Pedestrian signals stand in the curb furniture band just beyond the far edge of their zebra
## (away from the junction), beside the crossing rather than in its path.
const PED_SIGNAL_AT := WS.ZEBRA_FAR + 0.3 * WS.M
## Corners 0..3 = NE, SE, SW, NW: offsets and the approach arm each pole's heads face.
const CORNERS: Array[Vector2] = [Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1)]
## NE serves northbound traffic (from the S arm), SE eastbound (W arm), SW southbound (N arm),
## NW westbound (E arm): each on the far side of the junction, mast over the lane.
const CORNER_ARM: Array[int] = [2, 3, 0, 1]
const LAMP_COLS := [Color(1.0, 0.12, 0.06), Color(1.0, 0.55, 0.05), Color(0.1, 1.0, 0.45)]
const POLE_COL := Color(0.22, 0.23, 0.24)
const HOUSING_COL := Color(0.06, 0.065, 0.07)
const CONCRETE := Color(0.55, 0.54, 0.52)
const SIGN_RED := Color(0.62, 0.04, 0.05)
const SIGN_WHITE := Color(0.92, 0.92, 0.9)

var lg: LG
var sim: CitySim
var clock: float = 0.0
var root: Node3D
## The quality preset's visibility scale (CityView.vis_mult), set by the traffic feature; the
## signal/sign GLBs are ranged with it at build time (street_dressing's _range convention).
var vis_mult: float = 1.0
## tile -> {"node": Node3D, "groups": Array[MeshInstance3D] (axis * 3 + colour), "peds":
## Array[GeometryInstance3D] per (axis * 2 + walk), "poles": Array[Node3D], "state": int,
## "colliders": Array of holder-local solid entries (written into the view's holder meta)}
var props: Dictionary = {}
## The view's tile holder, so our posts can be written into its `colliders` meta (the channel
## CollisionWorld reads), and the collision refresh to call once they changed. traffic_feature
## wires both: only its ctx holds the view and the collision world.
var holder_of: Callable
var colliders_changed: Callable
var _on_mats: Array[StandardMaterial3D] = []
var _off_mats: Array[StandardMaterial3D] = []
var _walk_mats: Array[StandardMaterial3D] = []  # [hand off, hand on, man off, man on]
var _pole_mat: StandardMaterial3D
var _asset: PackedScene


func setup(p_lg: LG, p_root: Node3D) -> void:
	lg = p_lg
	sim = lg.sim
	root = p_root
	_pole_mat = KIT.vc_material(0.55, 0.35)
	_on_mats.clear()
	_off_mats.clear()
	for c: Color in LAMP_COLS:
		_on_mats.append(_lamp(c, 6.0))
		_off_mats.append(_lamp(c.darkened(0.82), 0.0))
	_walk_mats = [
		_lamp(Color(1.0, 0.5, 0.1).darkened(0.8), 0.0),
		_lamp(Color(1.0, 0.5, 0.1), 4.0),
		_lamp(Color(0.85, 0.95, 1.0).darkened(0.8), 0.0),
		_lamp(Color(0.85, 0.95, 1.0), 4.0)
	]
	_asset = AP.load_scene(AP.TRAFFIC_LIGHT)


static func _lamp(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.25
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = energy
	return m


func offset(i: int) -> float:
	return float(absi(hash(i * 7919 + 13)) % 32000) / 1000.0


## [axis green (0 N-S, 1 E-W), state GREEN/AMBER/RED for that axis, seconds into the state].
func phase(i: int) -> Array:
	var t := fposmod(clock + offset(i), CYCLE)
	var half := T_GREEN + T_AMBER + T_ALLRED
	var axis := 0 if t < half else 1
	var u := t - float(axis) * half
	if u < T_GREEN:
		return [axis, GREEN, u]
	if u < T_GREEN + T_AMBER:
		return [axis, AMBER, u - T_GREEN]
	return [axis, RED, u - T_GREEN - T_AMBER]


## Signal for traffic entering cross tile i from arm e (GREEN when the tile has no lights).
func light(i: int, e: int) -> int:
	var t: LG.TileInfo = lg.info(i)
	if t == null or not t.lights:
		return GREEN
	var ph := phase(i)
	var axis := 0 if (e == 0 or e == 2) else 1
	if int(ph[0]) != axis:
		return RED
	return int(ph[1])


## Seconds of green left for arm e (0 when not green).
func green_left(i: int, e: int) -> float:
	if light(i, e) != GREEN:
		return 0.0
	return T_GREEN - float(phase(i)[2])


## True when people may step onto the zebra across arm `arm` of signalled tile i: its walk phase
## follows the parallel green (zebras across N/S arms walk with E-W green).
func ped_walk(i: int, arm: int) -> bool:
	var ph := phase(i)
	var parallel := 1 if (arm == 0 or arm == 2) else 0
	return int(ph[0]) == parallel and int(ph[1]) == GREEN and float(ph[2]) < WALK_START


## True while the walk lamp of that zebra shows "walk" (the whole parallel green).
func ped_lamp(i: int, arm: int) -> bool:
	var ph := phase(i)
	var parallel := 1 if (arm == 0 or arm == 2) else 0
	return int(ph[0]) == parallel and int(ph[1]) == GREEN


# ------------------------------------------------------------------ props


## (Re)builds the furniture of every junction tile.
func rebuild_all() -> void:
	for i: int in props.keys():
		_free_props(i)
	props.clear()
	for i: int in lg.tiles.keys():
		build_props(i)


## Rebuilds the furniture of tile i (none unless it is a tee or a cross), then writes its solid
## parts into the tile's colliders.
func build_props(i: int) -> void:
	_free_props(i)
	var t: LG.TileInfo = lg.info(i)
	# Tracks have no curb to stand signs on and no signals.
	if t != null and root != null and t.grade == 0:
		if t.lights:
			props[i] = _build_cross(i)
		elif t.stem >= 0:
			props[i] = _build_tee(i, t)
	_sync_pole_colliders(i)


func _free_props(i: int) -> void:
	var p: Dictionary = props.get(i, {})
	if p.has("node") and is_instance_valid(p["node"]):
		(p["node"] as Node3D).queue_free()
	props.erase(i)


## Writes tile i's junction colliders into its holder's `colliders` meta, replacing our earlier
## entries, then refreshes collision. Runs on every build_props: the view rebuilds a tile's
## holder fresh (G1's furniture colliders with it), so our posts must be re-added each time.
func _sync_pole_colliders(i: int) -> void:
	if not holder_of.is_valid():
		return
	var holder: Node3D = holder_of.call(i)
	if holder == null:
		return
	var entries: Array = (props.get(i, {}) as Dictionary).get("colliders", [])
	var cols: Array = []
	for c: Variant in holder.get_meta("colliders", []):
		if typeof(c) == TYPE_DICTIONARY and str((c as Dictionary).get("kind", "")) == "signal":
			continue
		cols.append(c)
	cols.append_array(entries)
	holder.set_meta("colliders", cols)
	if colliders_changed.is_valid():
		colliders_changed.call(i)


## Holder-local collider entry for one of our posts, in metres: base_m raises it above the
## sidewalk (the shaft of a signal pole starts on top of its plinth). kind "signal" is ours --
## G1's dressing owns "sign" and the knockable street kinds.
func _post_collider(at: Vector2, r_m: float, h_m: float, base_m: float = 0.0) -> Dictionary:
	return {
		"shape": "cyl",
		"pos": Vector3(at.x, WS.SIDEWALK_TOP + base_m * WS.M, at.y),
		"r": r_m * WS.M,
		"h": h_m * WS.M,
		"yaw": 0.0,
		"kind": "signal"
	}


## A corner signal pole's solid parts: the concrete base and the shaft above it. The mast, the
## heads and the cap sit above people or reach over the carriageway -- overhangs stay visual by
## contract, and tools/tests/fp_overhang_test.gd walks the lane under them while keeping these
## entries footprint-sized. The base is a box the size of the drawn square (its foot's corners
## reach 0.40 m out, no fitting cylinder covers them) and stops short of the car's step height,
## so cars nose up to it like a curb; the shaft then holds the stop.
func _pole_colliders(at: Vector2) -> Array:
	return [_plinth_collider(at), _post_collider(at, 0.11, 6.15, 0.15)]


## Holder-local box collider for a pole's concrete base, in metres: the drawn base is a
## chamfered square (foot ±0.28 m at the ground, ±0.21 m by its 0.15 m top), so the box covers
## every corner with a 5 mm margin where a cylinder of any radius would miss some. kind "signal"
## is ours -- G1's dressing owns "sign" and the knockable street kinds.
func _plinth_collider(at: Vector2) -> Dictionary:
	return {
		"shape": "box",
		"pos": Vector3(at.x, WS.SIDEWALK_TOP, at.y),
		"size": Vector3(0.57, 0.15, 0.57) * WS.M,
		"yaw": 0.0,
		"kind": "signal"
	}


## The light pole on cross tile i at corner (0..3 = NE, SE, SW, NW), or null.
func light_pole(i: int, corner: int) -> Node3D:
	var p: Dictionary = props.get(i, {})
	var poles: Array = p.get("poles", [])
	return poles[corner] if corner >= 0 and corner < poles.size() else null


## Lamp states of cross tiles near p (within r): swaps materials only on change.
func update_lamps(p: Vector3, r: float) -> void:
	for i: int in props.keys():
		var pr: Dictionary = props[i]
		if not pr.has("groups"):
			continue
		var c := Vector2(D.tx(i), D.ty(i))
		if c.distance_squared_to(Vector2(p.x, p.z)) > r * r:
			continue
		var ph := phase(i)
		var walk_ns := ped_lamp(i, 1)
		var walk_ew := ped_lamp(i, 0)
		var key := int(ph[0]) * 3 + int(ph[1]) + (8 if walk_ns else 0) + (16 if walk_ew else 0)
		if int(pr.get("state", -1)) == key:
			continue
		pr["state"] = key
		var groups: Array = pr["groups"]
		for axis in range(2):
			var st := RED if int(ph[0]) != axis else int(ph[1])
			for col in range(3):
				for mi: GeometryInstance3D in groups[axis * 3 + col]:
					if is_instance_valid(mi):
						mi.material_override = (
							_on_mats[col] if col == _col_index(st) else _off_mats[col]
						)
		_show_peds(pr["peds"], walk_ns, walk_ew)


## Pedestrian heads: axis 0 are the zebras across E/W arms (walk with N-S green), axis 1 those
## across N/S arms; each zebra's hand and walking man swap materials together.
func _show_peds(peds: Array, walk_ns: bool, walk_ew: bool) -> void:
	for k in range(4):
		var walk := walk_ns if k / 2 == 0 else walk_ew
		var is_man := k % 2 == 1
		var lit := walk == is_man
		var mat := _walk_mats[(2 if is_man else 0) + (1 if lit else 0)]
		for g: GeometryInstance3D in peds[k]:
			if is_instance_valid(g):
				g.material_override = mat


static func _col_index(st: int) -> int:
	return 0 if st == RED else (1 if st == AMBER else 2)


func _tile_root(i: int, n: String) -> Node3D:
	var node := Node3D.new()
	node.name = "%s_%d" % [n, i]
	node.position = Vector3(D.tx(i), 0, D.ty(i))
	root.add_child(node)
	return node


func _build_cross(i: int) -> Dictionary:
	var node := _tile_root(i, "Lights")
	var kit: KIT = KIT.new()
	kit.begin()
	var lamps: Array = []  # axis * 3 + colour -> KIT
	var groups: Array = []  # axis * 3 + colour -> Array[GeometryInstance3D]
	for k in range(6):
		var lk: KIT = KIT.new()
		lk.begin()
		lamps.append(lk)
		groups.append([])
	var peds: Array = []
	for k in range(4):
		var pk: KIT = KIT.new()
		pk.begin()
		peds.append(pk)
	var ped_nodes: Array = [[], [], [], []]
	var poles: Array = []
	var cols: Array = []  # holder-local solid entries (see _sync_pole_colliders)
	var asset_ok := _asset != null
	for corner in range(4):
		var arm: int = CORNER_ARM[corner]
		var xf := _pole_xform(corner)
		var pole := Node3D.new()
		pole.name = "Pole_%d" % corner
		pole.transform = xf
		node.add_child(pole)
		poles.append(pole)
		cols.append_array(_pole_colliders(CORNERS[corner] * POLE_AT))
		var axis := 0 if (arm == 0 or arm == 2) else 1
		if asset_ok:
			var inst := _asset.instantiate() as Node3D
			if inst != null:
				pole.add_child(inst)
				_range_asset(inst)
				_bind_asset_lamps(inst, axis, groups)
				_bind_asset_peds(inst, 1 - axis, ped_nodes)
				continue
		_pole_mesh(kit, xf, lamps, axis)
		for nm: String in ["SignText_A", "SignText_B"]:
			var m := Node3D.new()
			m.name = nm
			m.position = Vector3(-0.05 * WS.M, (4.6 if nm == "SignText_A" else 4.35) * WS.M, 0.0)
			m.rotation.y = 0.0 if nm == "SignText_A" else PI * 0.5
			pole.add_child(m)
	# Pedestrian signals at both ends of each zebra, in the curb furniture band beside it.
	var lat := (WS.CURB_FURNITURE[0] + WS.CURB_FURNITURE[1]) * 0.5
	for arm in range(4):
		var a := LG.DIRS[arm]
		var p := Vector2(-a.y, a.x)
		var axis := 0 if (arm == 1 or arm == 3) else 1
		for s: float in [1.0, -1.0]:
			var at := a * PED_SIGNAL_AT + p * (s * lat)
			cols.append(_post_collider(at, 0.06, 2.9))
			var face := -p * s
			_ped_signal(kit, at, face, peds[axis * 2], peds[axis * 2 + 1])
	var mesh := kit.commit()
	if mesh != null:
		var mi := _mi(mesh, _pole_mat, true)
		node.add_child(mi)
	for k in range(6):
		var lm: ArrayMesh = (lamps[k] as KIT).commit()
		if lm != null:
			var g := _mi(lm, _off_mats[k % 3], false)
			node.add_child(g)
			(groups[k] as Array).append(g)
	for k in range(4):
		var pm: ArrayMesh = (peds[k] as KIT).commit()
		if pm != null:
			var g := _mi(pm, _walk_mats[k % 2 * 2], false)
			node.add_child(g)
			(ped_nodes[k] as Array).append(g)
	return {
		"node": node,
		"groups": groups,
		"peds": ped_nodes,
		"poles": poles,
		"state": -1,
		"colliders": cols
	}


func _mi(mesh: Mesh, mat: Material, shadows: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if shadows and vis_mult >= 1.0
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	mi.visibility_range_end = WS.VIS_PROP * vis_mult
	mi.visibility_range_end_margin = 0.5
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mi


## Tile-local transform of the pole at `corner`: local -X (the mast) points along the far side of
## the junction toward the lane it serves; local +Z faces the approaching traffic.
func _pole_xform(corner: int) -> Transform3D:
	var c := CORNERS[corner] * POLE_AT
	var arm: int = CORNER_ARM[corner]
	var face := LG.DIRS[arm]  # toward the approach the heads face
	var z := Vector3(face.x, 0, face.y)
	var y := Vector3.UP
	var x := y.cross(z)
	return Transform3D(Basis(x, y, z), Vector3(c.x, WS.SIDEWALK_TOP, c.y))


func _pole_mesh(kit: KIT, xf: Transform3D, lamps: Array, axis: int) -> void:
	var M := WS.M
	kit.cyl(xf, 0.24 * M, 0.24 * M, 0.25 * M, CONCRETE, 10)
	kit.cyl(xf, 0.11 * M, 0.08 * M, 6.4 * M, POLE_COL, 10)
	# Mast arm along -X at 5.9 m with a tie rod.
	var arm_xf := xf * Transform3D(Basis(), Vector3(-MAST * 0.5, 5.9 * M, 0))
	kit.box(arm_xf, Vector3(MAST, 0.13 * M, 0.13 * M), POLE_COL)
	var tie_xf := (
		xf * Transform3D(Basis(Vector3(0, 0, 1), atan2(0.55, 3.0)), Vector3(-1.5 * M, 6.225 * M, 0))
	)
	kit.box(tie_xf, Vector3(3.05 * M, 0.04 * M, 0.04 * M), POLE_COL)
	kit.cyl(
		xf * Transform3D(Basis(), Vector3(0, 6.4 * M, 0)), 0.12 * M, 0.02 * M, 0.25 * M, POLE_COL, 8
	)
	# Main head hanging from the mast over the lane, and a secondary head on the pole.
	_head(kit, xf * Transform3D(Basis(), Vector3(-MAST + 0.35 * M, 5.15 * M, 0)), lamps, axis, true)
	_head(kit, xf * Transform3D(Basis(), Vector3(0, 3.4 * M, 0.24 * M)), lamps, axis, false)


## A three-lamp signal head centred at xf, facing +Z.
func _head(kit: KIT, xf: Transform3D, lamps: Array, axis: int, hanging: bool) -> void:
	var M := WS.M
	kit.box(xf, Vector3(0.36 * M, 1.02 * M, 0.26 * M), HOUSING_COL)
	kit.box(
		xf * Transform3D(Basis(), Vector3(0, 0, -0.14 * M)),
		Vector3(0.62 * M, 1.26 * M, 0.02 * M),
		HOUSING_COL
	)
	if hanging:
		kit.box(
			xf * Transform3D(Basis(), Vector3(0, 0.62 * M, 0)),
			Vector3(0.05 * M, 0.25 * M, 0.05 * M),
			POLE_COL
		)
	else:
		kit.box(
			xf * Transform3D(Basis(), Vector3(0, 0, -0.2 * M)),
			Vector3(0.08 * M, 0.08 * M, 0.14 * M),
			POLE_COL
		)
	for col in range(3):
		var y := (0.32 - 0.32 * float(col)) * M
		var lx := xf * Transform3D(Basis(), Vector3(0, y, 0.135 * M))
		(lamps[axis * 3 + col] as KIT).disc(lx, 0.12 * M, LAMP_COLS[col], 14)
		# Visor above each lamp.
		kit.box(
			xf * Transform3D(Basis(), Vector3(0, y + 0.135 * M, 0.22 * M)),
			Vector3(0.3 * M, 0.02 * M, 0.18 * M),
			HOUSING_COL
		)


## Pedestrian signal pole at tile-local at, its head facing `face` (across the zebra).
func _ped_signal(kit: KIT, at: Vector2, face: Vector2, hand: KIT, man: KIT) -> void:
	var M := WS.M
	var z := Vector3(face.x, 0, face.y)
	var x := Vector3.UP.cross(z)
	var xf := Transform3D(Basis(x, Vector3.UP, z), Vector3(at.x, WS.SIDEWALK_TOP, at.y))
	kit.cyl(xf, 0.06 * M, 0.05 * M, 2.9 * M, POLE_COL, 8)
	var hx := xf * Transform3D(Basis(), Vector3(0, 2.45 * M, 0.12 * M))
	kit.box(hx, Vector3(0.34 * M, 0.62 * M, 0.2 * M), HOUSING_COL)
	hand.disc(
		hx * Transform3D(Basis(), Vector3(0, 0.15 * M, 0.105 * M)),
		0.11 * M,
		Color(1.0, 0.5, 0.1),
		4,
		PI * 0.25
	)
	man.disc(
		hx * Transform3D(Basis(), Vector3(0, -0.15 * M, 0.105 * M)),
		0.11 * M,
		Color(0.85, 0.95, 1.0),
		4,
		PI * 0.25
	)


## The signal and sign GLBs arrive unranged: without this every lamp lens and sign face in the
## city drew at every distance (790 of 2732 draws on the day-10 draw census). Range them like the
## kit parts (_mi): VIS_PROP scaled by the quality preset, dithered out over half a metre. On the
## web tier they also leave the shadow pass: a lens or sign face casts nothing a walker reads.
func _range_asset(inst: Node3D) -> void:
	for n in inst.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if vis_mult < 1.0:
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if gi.visibility_range_end != 0.0:
			continue
		gi.visibility_range_end = WS.VIS_PROP * vis_mult
		gi.visibility_range_end_margin = 0.5
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


## Binds H's traffic-light asset lamps (Signal_Red_*, Signal_Amber_*, Signal_Green_*) into the
## lamp groups: each node gets its own material_override on state changes.
func _bind_asset_lamps(inst: Node, axis: int, groups: Array) -> void:
	var prefixes := ["Signal_Red", "Signal_Amber", "Signal_Green"]
	for n in inst.find_children("Signal_*", "GeometryInstance3D", true, false):
		for col in range(3):
			if str(n.name).begins_with(prefixes[col]):
				(groups[axis * 3 + col] as Array).append(n)


## Binds the asset pole's pedestrian head (DontWalk_*, Walk_*) to the zebra it faces. The head
## looks along the pole's -X, across the arm its traffic heads come from, so it serves the zebras
## of ped axis 1 - (the light axis).
func _bind_asset_peds(inst: Node, ped_axis: int, peds: Array) -> void:
	for n in inst.find_children(AP.DONT_WALK_NODE_PREFIX + "*", "GeometryInstance3D", true, false):
		(peds[ped_axis * 2] as Array).append(n)
	for n in inst.find_children(AP.WALK_NODE_PREFIX + "*", "GeometryInstance3D", true, false):
		(peds[ped_axis * 2 + 1] as Array).append(n)


func _build_tee(i: int, t: LG.TileInfo) -> Dictionary:
	var node := _tile_root(i, "Sign")
	var kit: KIT = KIT.new()
	kit.begin()
	var s: int = t.stem
	var a := LG.DIRS[s]
	var inbound := -a
	var right := Vector2(-inbound.y, inbound.x)
	var lat := (WS.CURB_FURNITURE[0] + WS.CURB_FURNITURE[1]) * 0.5
	var at := a * LG.STOP_FRONT + right * lat
	var face := Vector3(a.x, 0, a.y)
	var x := Vector3.UP.cross(face)
	var xf := Transform3D(Basis(x, Vector3.UP, face), Vector3(at.x, WS.SIDEWALK_TOP, at.y))
	var M := WS.M
	var yield_sign := t.stem_residential
	var path := AP.YIELD_SIGN if yield_sign else AP.STOP_SIGN
	var ps := AP.load_scene(path)
	if ps != null:
		var inst := ps.instantiate() as Node3D
		inst.transform = xf
		node.add_child(inst)
		_range_asset(inst)
	else:
		kit.cyl(xf, 0.045 * M, 0.045 * M, 2.55 * M, POLE_COL, 8)
		var px := xf * Transform3D(Basis(), Vector3(0, 2.25 * M, 0.06 * M))
		if yield_sign:
			var r := 0.5 * M
			var pts := [
				Vector3(0, -r, 0), Vector3(r * 0.866, r * 0.5, 0), Vector3(-r * 0.866, r * 0.5, 0)
			]
			kit.tri_plate(px, pts[0], pts[1], pts[2], SIGN_RED)
			var ri := r * 0.62
			var inner := [
				Vector3(0, -ri, 0),
				Vector3(ri * 0.866, ri * 0.5, 0),
				Vector3(-ri * 0.866, ri * 0.5, 0)
			]
			kit.tri_plate(
				px * Transform3D(Basis(), Vector3(0, 0, 0.004 * M)),
				inner[0],
				inner[1],
				inner[2],
				SIGN_WHITE
			)
			kit.box(
				px * Transform3D(Basis(), Vector3(0, 0, -0.012 * M)),
				Vector3(0.7 * M, 0.55 * M, 0.02 * M),
				Color(0.5, 0.5, 0.52)
			)
		else:
			kit.disc(px, 0.4 * M, SIGN_WHITE, 8, PI / 8.0)
			kit.disc(
				px * Transform3D(Basis(), Vector3(0, 0, 0.004 * M)), 0.36 * M, SIGN_RED, 8, PI / 8.0
			)
			kit.box(
				px * Transform3D(Basis(), Vector3(0, 0, -0.012 * M)),
				Vector3(0.74 * M, 0.74 * M, 0.02 * M),
				Color(0.5, 0.5, 0.52)
			)
			var lbl := Label3D.new()
			lbl.text = "STOP"
			lbl.font_size = 64
			lbl.outline_size = 0
			lbl.pixel_size = 0.0022 * M
			lbl.modulate = SIGN_WHITE
			lbl.double_sided = false
			lbl.shaded = true
			lbl.visibility_range_end = 1.5
			lbl.transform = px * Transform3D(Basis(), Vector3(0, 0, 0.01 * M))
			node.add_child(lbl)
	# The sign pole is solid (the kit fallback and the sign asset stand on the same spot).
	var cols: Array = [_post_collider(at, 0.045, 2.55)]
	var mesh := kit.commit()
	if mesh != null:
		node.add_child(_mi(mesh, _pole_mat, true))
	return {
		"node": node,
		"sign": at + Vector2(D.tx(i), D.ty(i)),
		"kind": "yield" if yield_sign else "stop",
		"colliders": cols
	}
