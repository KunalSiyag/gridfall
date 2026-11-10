class_name ShoreRocks
extends RefCounted
## Cobbles and boulders along the river banks (materials unit G2). The sim has only land and water,
## so a bank was sand running straight into water; a few stones half sunk in the sand break that
## line and read as rock. They are the already-shipped rock_boulder.glb (Poly Haven rock_07, 1,187
## triangles) scattered by a hash of the city seed and the tile, so the same city always has the
## same stones: one MultiMesh per 16-tile chunk (so the renderer culls them and each is one draw),
## no shadows, drawn out to 90 m, on foot only (CityView hides the node in the Planner). A rock-slab
## material on the bank would have needed a steep bank and more shader work on the ground, and the
## banks are gentle (a 4 m shelf); a stone's silhouette is what the eye misses. They have no
## collision: they are 0.2 to 0.65 m high and the hero walks through them.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SHORE := preload("res://scripts/world/shore.gd")

const MODEL := "res://models/real/props/rock_boulder.glb"
## Tiles to a chunk side. A chunk is a node whose origin is its stones' centre: the renderer
## measures a visibility range from the node, so stones placed in world coordinates under an origin
## node would all be judged by their distance from the world's corner and never draw.
const CHUNK := 8
## Percent of the land tiles at the water that have a stone (and, of those, that have a second).
## The look-polish pass (flag look_polish) raises both, so the default shore poses show stones (at 35
## a pose by the water often had none in view), and the second stone lies against the first, smaller,
## as stones do; with the flag off the first look: 35 and 40, the second stone anywhere on the tile.
const SHARE := 35
const SECOND := 40
const SHARE_POLISH := 55
const SECOND_POLISH := 50
## How near a clustered stone lies to the first (tile units) and how big it is beside it.
const CLUSTER := 0.035
const CLUSTER_SIZE := Vector2(0.35, 0.7)
## How far from the water's edge a stone sits, in tile units: inside the part of the sand band that
## is fully sand (SHORE.SHORE_W is 0.15 and the band is half sand at about a third of that), never
## out on the grass.
const DEPTH := Vector2(0.005, 0.07)
## Scale of the model (it is 0.71 x 0.6 x 1.35 m), and how much of its height is below the sand.
const SIZE := Vector2(0.45, 1.1)
const SINK := 0.25
const MODEL_HEIGHT := 0.03
## Draw distance of a chunk's centre, in tile units, and the half-diagonal of a chunk added to it
## (the farthest stone of a chunk that is in range is that far beyond its centre).
const RANGE := 90.0 * WS.M
const REACH := CHUNK * 0.7
## The four sides then the four corners, as SHORE.water_flags orders them (N, E, S, W, NW, NE, SE,
## SW): the direction from the tile's centre toward each, in tile units (north is -y).
const TOWARD: Array[Vector2] = [
	Vector2(0, -1),
	Vector2(1, 0),
	Vector2(0, 1),
	Vector2(-1, 0),
	Vector2(-1, -1),
	Vector2(1, -1),
	Vector2(1, 1),
	Vector2(-1, 1),
]


## The stone transforms for a city, by chunk: Vector2i (tile / CHUNK) -> Array[Transform3D]. Pure of
## the sim's terrain and seed.
static func placements(sim: CitySim, polish: bool = true) -> Dictionary:
	var out: Dictionary = {}
	var share := SHARE_POLISH if polish else SHARE
	var second := SECOND_POLISH if polish else SECOND
	var mask := SHORE.mask(sim)
	for i in range(D.W * D.H):
		if mask[i] == 0:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		var r := RandomNumberGenerator.new()
		r.seed = hash([sim.city_seed, i, "shore_rock"])
		if r.randi() % 100 >= share:
			continue
		var flags := SHORE.water_flags(sim, x, y)
		var stones := 2 if r.randi() % 100 < second else 1
		var first := Transform3D()
		for n in range(stones):
			var xf := _stone(r, flags, x, y)
			if polish and n == 1 and first != Transform3D():
				xf = _beside(r, first, flags)
			if xf == Transform3D():
				continue
			if n == 0:
				first = xf
			var key := Vector2i(floori(float(x) / CHUNK), floori(float(y) / CHUNK))
			if not out.has(key):
				out[key] = [] as Array[Transform3D]
			(out[key] as Array[Transform3D]).append(xf)
	return out


## One stone on land tile (x, y) whose water neighbours are `flags`: near a side that has water, or
## the corner when only that is wet. Identity when the tile has none (cannot happen for a shore
## tile).
static func _stone(r: RandomNumberGenerator, flags: Array[bool], x: int, y: int) -> Transform3D:
	var wet: Array[int] = []
	for k in range(4):
		if flags[k]:
			wet.append(k)
	var depth := r.randf_range(DEPTH.x, DEPTH.y)
	var along := r.randf_range(-0.42, 0.42)
	var spot := Vector2.ZERO
	if not wet.is_empty():
		var k: int = wet[r.randi() % wet.size()]
		var toward := TOWARD[k]
		spot = toward * (0.5 - depth) + Vector2(-toward.y, toward.x) * along
	else:
		for k in range(4, 8):
			if flags[k]:
				wet.append(k)
		if wet.is_empty():
			return Transform3D()
		spot = TOWARD[wet[r.randi() % wet.size()]] * (0.5 - depth)
	var s := r.randf_range(SIZE.x, SIZE.y)
	var basis := (
		Basis(Vector3.UP, r.randf() * TAU)
		* Basis.from_scale(
			Vector3(
				s * r.randf_range(0.8, 1.25),
				s * r.randf_range(0.7, 1.0),
				s * r.randf_range(0.8, 1.25)
			)
		)
	)
	var origin := Vector3(x + spot.x, WS.GROUND_Y - SINK * MODEL_HEIGHT * s, y + spot.y)
	return Transform3D(basis, origin)


## A smaller stone lying against `first` (a clustered pair, not two unrelated stones).
static func _beside(
	r: RandomNumberGenerator, first: Transform3D, flags: Array[bool]
) -> Transform3D:
	var a := r.randf() * TAU
	var k := r.randf_range(CLUSTER_SIZE.x, CLUSTER_SIZE.y)
	var basis := Basis(Vector3.UP, r.randf() * TAU) * first.basis.scaled(Vector3.ONE * k)
	# Never toward the water: a stone beside the first one stays on the sand side of it.
	var dir := Vector2(cos(a), sin(a))
	var wet := Vector2.ZERO
	for i in range(8):
		if flags[i]:
			wet += TOWARD[i]
	if wet != Vector2.ZERO and dir.dot(wet.normalized()) > 0.0:
		dir = dir.reflect(wet.normalized().orthogonal())
	var at := first.origin + Vector3(dir.x, 0.0, dir.y) * CLUSTER
	at.y = WS.GROUND_Y - SINK * MODEL_HEIGHT * first.basis.get_scale().y * k
	return Transform3D(basis, at)


## The boulder's mesh from the shipped model (its first mesh, with its own material), or null when
## the model is not there (a split web build whose props pack is not mounted yet).
static func load_mesh() -> Mesh:
	if not ResourceLoader.exists(MODEL):
		return null
	var ps := load(MODEL) as PackedScene
	if ps == null:
		return null
	var root := ps.instantiate()
	var mesh: Mesh = null
	for n in root.find_children("*", "MeshInstance3D", true, false):
		mesh = (n as MeshInstance3D).mesh
		if mesh != null:
			break
	root.free()
	return mesh


## Where a chunk's node sits: the mean of its stones' origins.
static func centre_of(xfs: Array[Transform3D]) -> Vector3:
	var centre := Vector3.ZERO
	for xf in xfs:
		centre += xf.origin
	return centre / float(maxi(xfs.size(), 1))


## The stones of a city as a node holding one MultiMeshInstance3D per chunk; null with no mesh or no
## stone. Unshadowed, each chunk drawn to RANGE + REACH from its centre.
static func build(sim: CitySim, mesh: Mesh, polish: bool = true) -> Node3D:
	if mesh == null:
		return null
	var by_chunk := placements(sim, polish)
	if by_chunk.is_empty():
		return null
	var root := Node3D.new()
	root.name = "ShoreRocks"
	for key: Vector2i in by_chunk.keys():
		var xfs: Array[Transform3D] = by_chunk[key]
		var centre := centre_of(xfs)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = xfs.size()
		for j in range(xfs.size()):
			mm.set_instance_transform(j, Transform3D(xfs[j].basis, xfs[j].origin - centre))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Rocks_%d_%d" % [key.x, key.y]
		mmi.multimesh = mm
		mmi.position = centre
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = RANGE + REACH
		mmi.visibility_range_end_margin = 0.5
		root.add_child(mmi)
	return root
