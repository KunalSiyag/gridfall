extends RefCounted
## The water surface mesh and the hero's ripples, kept out of CityView (a file near its line cap).
## Preload as WATER.
##
## mesh(): one flat quad per open-water tile at height y, with a vertex colour that carries the
## current for shaders/water.gdshader: COLOR.rg = flow * 0.5 + 0.5 (0.5 = still), COLOR.b = 0. A
## tile's current runs along the axis it continues in (east-west when its east and west neighbours
## are water, north-south for the north and south ones; a lake tile, with both, is still) and is
## averaged over the four tiles round each corner, so the current turns smoothly at a bend. The
## sign is the same everywhere (towards +x and +z), so neighbours always agree.
##
## Ripples is the shader's footfall array: up to SLOTS rings, each (x, z, age, amplitude).

const D := preload("res://scripts/sim/sim_defs.gd")

## Rings alive at once; the same number as `uniform vec4 ripples[4]` in the shader.
const SLOTS := 4
## Seconds a ring lives (the shader fades it over 1.6 s).
const LIFE := 1.6


## True when the renderer is the web build's gl_compatibility (the string
## RenderingServer.get_current_rendering_method() returns), whose depth buffer the water shader
## must unproject with the remapped screen uv.
static func is_compat(rendering_method: String) -> bool:
	return rendering_method == "gl_compatibility"


## The current of open-water tile (x, y): +x, +z, or the diagonal at a bend; zero in a lake and
## on land.
static func tile_flow(sim: CitySim, x: int, y: int) -> Vector2:
	if not _wet(sim, x, y):
		return Vector2.ZERO
	var ew := int(_wet(sim, x - 1, y)) + int(_wet(sim, x + 1, y))
	var ns := int(_wet(sim, x, y - 1)) + int(_wet(sim, x, y + 1))
	if ew == 2 and ns == 2:
		return Vector2.ZERO
	if ew > ns:
		return Vector2(1.0, 0.0)
	if ns > ew:
		return Vector2(0.0, 1.0)
	return Vector2(0.7071, 0.7071)


## The current at the tile corner (cx, cy) (its north-west corner is (x - 0.5, y - 0.5) of tile
## (x, y), so corner (cx, cy) touches tiles cx - 1..cx, cy - 1..cy): the mean over the water
## tiles round it, zero with none.
static func corner_flow(sim: CitySim, cx: int, cy: int) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for dy in range(-1, 1):
		for dx in range(-1, 1):
			if _wet(sim, cx + dx, cy + dy):
				sum += tile_flow(sim, cx + dx, cy + dy)
				n += 1
	return sum / float(n) if n > 0 else Vector2.ZERO


## The surface at height y: a quad per open-water tile, UV = world xz, a flat up normal, the
## current in the vertex colour.
static func mesh(sim: CitySim, y: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	var any := false
	var memo := {}
	for i in range(D.W * D.H):
		if sim.terrain[i] != D.WATER:
			continue
		any = true
		var x := D.tx(i)
		var z := D.ty(i)
		# Corners in the order of the old tile quad: a, b, d, a, d, e.
		var a := Vector2i(x, z)
		var b := Vector2i(x + 1, z)
		var d := Vector2i(x + 1, z + 1)
		var e := Vector2i(x, z + 1)
		for c: Vector2i in [a, b, d, a, d, e]:
			var key := D.idx(c.x, c.y) if D.in_bounds(c.x, c.y) else -(c.x * 1024 + c.y) - 1
			if not memo.has(key):
				memo[key] = corner_flow(sim, c.x, c.y)
			var f: Vector2 = memo[key]
			st.set_color(Color(f.x * 0.5 + 0.5, f.y * 0.5 + 0.5, 0.0, 1.0))
			st.set_uv(Vector2(c.x - 0.5, c.y - 0.5))
			st.add_vertex(Vector3(c.x - 0.5, y, c.y - 0.5))
	if not any:
		return ArrayMesh.new()
	return st.commit()


static func _wet(sim: CitySim, x: int, y: int) -> bool:
	return D.in_bounds(x, y) and sim.terrain[D.idx(x, y)] == D.WATER


## The footfall rings: add() on a step, tick() once a frame while alive. Pure state; CityView owns
## one and copies array() into the material.
class Ripples:
	extends RefCounted
	## x, z, age, amplitude per slot; age < 0 is a free slot.
	var slots: Array[Vector4] = []
	var _next := 0

	func _init() -> void:
		for _k in range(SLOTS):
			slots.append(Vector4(0.0, 0.0, -1.0, 0.0))

	## Starts a ring at (x, z) of amplitude amp (0..1), over the oldest slot when all are alive.
	func add(x: float, z: float, amp: float) -> void:
		var k := -1
		for j in range(SLOTS):
			if slots[j].z < 0.0:
				k = j
				break
		if k < 0:
			k = _next
			_next = (_next + 1) % SLOTS
		slots[k] = Vector4(x, z, 0.0, clampf(amp, 0.0, 1.0))

	## Ages every live ring by dt; a ring past LIFE frees its slot. True while any is alive.
	func tick(dt: float) -> bool:
		var alive := false
		for j in range(SLOTS):
			if slots[j].z < 0.0:
				continue
			var s := slots[j]
			s.z += dt
			if s.z >= LIFE:
				s.z = -1.0
			else:
				alive = true
			slots[j] = s
		return alive

	func alive() -> bool:
		for j in range(SLOTS):
			if slots[j].z >= 0.0:
				return true
		return false

	func array() -> PackedVector4Array:
		return PackedVector4Array(slots)
