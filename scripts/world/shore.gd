extends RefCounted
## The shore band (CityView, on foot): sand and wet mud along every bank, with no new texture and
## no finer mesh. Every land tile that touches water is its own flat quad whose vertex colour codes
## which of its eight neighbours are water (COLOR.r = N, E, S, W bits / 15, COLOR.g = NW, NE, SE, SW
## bits / 15, COLOR.a = TILE_MARK); shaders/ground_detail.gdshader rebuilds the distance to the
## water per pixel from the tile-local position, exactly as RiverBed.land_distance does, and turns
## it into sand (SHORE_W wide) and wet sand (a third of that). So the band is exact at any distance
## and costs two triangles a tile. The river bed carries the two numbers itself, from its height
## (COLOR.rg = sand, wet, COLOR.a = BED_MARK). Any other mesh has no such alpha (white, or a
## model's own colours) and the shader reads no shore there: lots, lawns and tracks stay as they
## were. Preload as SHORE.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const RB := preload("res://scripts/fp/world/riverbed.gd")

## Width of the sand band on the land, in tile units (3 m), and of the wet strip (1 m).
const SHORE_W := 0.15
const WET_W := SHORE_W / 3.0
## COLOR.a of a shore tile (neighbours coded in r, g) and of a bed vertex (sand and wet in r, g).
const TILE_MARK := 0.5
const BED_MARK := 0.25
## Colour of a vertex outside the band (and of every vertex of a mesh that has no band).
const NONE := Color(1.0, 1.0, 1.0, 1.0)


## One byte per tile (D.idx order): 1 for a land tile that touches water on a side or a corner.
## Walks the water tiles only (a few thousand of 37 000), not every tile's eight neighbours.
static func mask(sim: CitySim) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(D.W * D.H)
	for i in range(D.W * D.H):
		if sim.terrain[i] != D.WATER:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if D.in_bounds(x + dx, y + dy) and sim.terrain[D.idx(x + dx, y + dy)] != D.WATER:
					out[D.idx(x + dx, y + dy)] = 1
	return out


## The water neighbours of land tile (x, y) in RB.land_flags order (N, E, S, W, NW, NE, SE, SW).
static func water_flags(sim: CitySim, x: int, y: int) -> Array[bool]:
	var out: Array[bool] = []
	for f: bool in RB.land_flags(sim, x, y):
		out.append(not f)
	return out


## The vertex colour that codes eight water flags (the shader decodes it).
static func encode(water: Array[bool]) -> Color:
	var edges := 0
	var corners := 0
	for k in range(4):
		edges |= int(water[k]) << k
		corners |= int(water[4 + k]) << k
	return Color(float(edges) / 15.0, float(corners) / 15.0, 0.0, TILE_MARK)


## The eight water flags a tile colour codes (encode()'s inverse, as the shader reads it).
static func decode(c: Color) -> Array[bool]:
	var edges := roundi(c.r * 15.0)
	var corners := roundi(c.g * 15.0)
	var out: Array[bool] = []
	for k in range(4):
		out.append((edges >> k) & 1 == 1)
	for k in range(4):
		out.append((corners >> k) & 1 == 1)
	return out


## Sand and wet (0..1) at distance dist (tile units) from the water: Vector2(sand, wet).
static func band(dist: float) -> Vector2:
	return Vector2(1.0 - smoothstep(0.0, SHORE_W, dist), 1.0 - smoothstep(0.0, WET_W, dist))


## The band colour of a bed vertex at height h (u): the bank above the waterline is sand, darkest
## and wettest at the waterline, and the sand thins out into silt below it.
static func bed_color(h: float) -> Color:
	var sand := lerpf(1.0, 0.25, smoothstep(WS.WATER_Y, WS.RIVERBED_Y, h))
	var wet := smoothstep(WS.WATER_Y * 0.35, WS.WATER_Y, h)
	return Color(sand, wet, 0.0, BED_MARK)


## Adds land tile (x, y) at height y_top to st as one quad coded with its water neighbours (normal
## up, uv = world xz, as the plain ground quads).
static func add_tile(st: SurfaceTool, sim: CitySim, x: int, y: int, y_top: float) -> void:
	var code := encode(water_flags(sim, x, y))
	var a := Vector3(x - 0.5, y_top, y - 0.5)
	var b := Vector3(x + 0.5, y_top, y - 0.5)
	var c := Vector3(x + 0.5, y_top, y + 0.5)
	var d := Vector3(x - 0.5, y_top, y + 0.5)
	for v: Vector3 in [a, b, c, a, c, d]:
		st.set_normal(Vector3.UP)
		st.set_color(code)
		st.set_uv(Vector2(v.x, v.z))
		st.add_vertex(v)
