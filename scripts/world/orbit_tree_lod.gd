class_name OrbitTreeLod
extends RefCounted
## The Planner's tree level of detail, decided per LOD cell and not per culling chunk.
## The orbit forest is planted in small chunks (CityView.TREE_CHUNK_ORBIT tiles) so the renderer can
## cull it to the view and the sun's shadow cascades; but the full trees against round stand-ins
## switch used to be a visibility range on each layer, measured from the centre of that layer's own
## AABB, and with the small chunks that switch moved to a finer grain than the look was made for
## (forests turned from dense stand-ins into sparse full models mid zoom, with a hard edge between).
## Here every layer has no range of its own and a cell of CELL_TILES tiles (the old chunk) holds the
## near/far state for all the chunks in it: near while the camera is within near_end of the cell's
## centre (the centre of the box its trees fill: the engine measured a range from the centre of the
## layer's AABB, not from the mean of the trees), with a hysteresis margin so the switch does not
## flicker (the engine's own rule: it appears inside near_end - margin and goes outside near_end +
## margin). The state is applied as the layers' `visible`: one pass over a handful of cells
## a frame, and a few dozen layer toggles when a cell crosses the line.

## Tiles to a LOD cell: the old orbit chunk.
const CELL_TILES := 48

## Cell (Vector2i) -> {"lo": Vector3, "hi": Vector3 (the box its trees fill), "n": int,
## "near": bool, "chunks": {chunk key -> {"near": Array, "far": Array, "n": int, "lo", "hi"}}}.
var _cells: Dictionary = {}
var _chunk_cell: Dictionary = {}
var _cam: Vector3 = Vector3.ZERO
var _have_cam: bool = false
## World distance to a cell's centre inside which its full trees draw, and the hysteresis around it.
var near_end: float = 120.0
var margin: float = 6.0


## The cell that holds orbit chunk c (the key's x, y), chunks of chunk_tiles tiles.
static func cell_of(c: Vector3i, chunk_tiles: int) -> Vector2i:
	return Vector2i(
		floori(float(c.x * chunk_tiles) / float(CELL_TILES)),
		floori(float(c.y * chunk_tiles) / float(CELL_TILES))
	)


## Registers chunk c's layers (near: the full models, far: the stand-ins) and its trees (their
## count and the box they fill, lo to hi, tree models included: the cell's centre is the centre of
## the union of its chunks' boxes), replacing what it had, and puts the layers in the cell's state.
func set_chunk(
	c: Vector3i,
	chunk_tiles: int,
	near_layers: Array,
	far_layers: Array,
	count: int,
	lo: Vector3,
	hi: Vector3
) -> void:
	drop_chunk(c)
	var cell_key := cell_of(c, chunk_tiles)
	var fresh := not _cells.has(cell_key)
	var cell: Dictionary = _cells.get(
		cell_key, {"lo": lo, "hi": hi, "n": 0, "near": false, "chunks": {}}
	)
	(cell["chunks"] as Dictionary)[c] = {
		"near": near_layers, "far": far_layers, "n": count, "lo": lo, "hi": hi
	}
	_cells[cell_key] = cell
	_refit(cell)
	_chunk_cell[c] = cell_key
	if _have_cam:
		# A cell with no state yet is judged on the line itself; one that has it keeps its margin.
		cell["near"] = (
			_cam.distance_to(centre_of(cell)) < near_end
			if fresh
			else _near_now(cell, bool(cell["near"]))
		)
	_apply_chunk(cell["chunks"][c], bool(cell["near"]))


## Forgets chunk c (its layers are the caller's to free).
func drop_chunk(c: Vector3i) -> void:
	if not _chunk_cell.has(c):
		return
	var cell_key: Vector2i = _chunk_cell[c]
	_chunk_cell.erase(c)
	var cell: Dictionary = _cells[cell_key]
	var chunks: Dictionary = cell["chunks"]
	chunks.erase(c)
	if chunks.is_empty():
		_cells.erase(cell_key)
	else:
		_refit(cell)


## Moves the camera: every cell whose state changed puts its layers in it. Returns how many did.
func update(cam: Vector3) -> int:
	_cam = cam
	_have_cam = true
	var flipped := 0
	for cell: Dictionary in _cells.values():
		var was := bool(cell["near"])
		var now := _near_now(cell, was)
		if now == was:
			continue
		cell["near"] = now
		flipped += 1
		for ch: Dictionary in (cell["chunks"] as Dictionary).values():
			_apply_chunk(ch, now)
	return flipped


## True when the cell of chunk c draws its full trees now.
func is_near(c: Vector3i, chunk_tiles: int) -> bool:
	var cell: Variant = _cells.get(cell_of(c, chunk_tiles))
	return cell != null and bool((cell as Dictionary)["near"])


## The cell's centre: the centre of the box its trees fill.
func centre_of(cell: Dictionary) -> Vector3:
	return ((cell["lo"] as Vector3) + (cell["hi"] as Vector3)) * 0.5


## The cell's box and tree count from its chunks.
func _refit(cell: Dictionary) -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var n := 0
	for ch: Dictionary in (cell["chunks"] as Dictionary).values():
		lo = lo.min(ch["lo"])
		hi = hi.max(ch["hi"])
		n += int(ch["n"])
	cell["lo"] = lo
	cell["hi"] = hi
	cell["n"] = n


func cell_count() -> int:
	return _cells.size()


func _near_now(cell: Dictionary, was_near: bool) -> bool:
	var d := _cam.distance_to(centre_of(cell))
	return d < near_end + margin if was_near else d < near_end - margin


func _apply_chunk(ch: Dictionary, near: bool) -> void:
	for n: Variant in ch["near"]:
		if is_instance_valid(n):
			(n as Node3D).visible = near
	for n: Variant in ch["far"]:
		if is_instance_valid(n):
			(n as Node3D).visible = not near
