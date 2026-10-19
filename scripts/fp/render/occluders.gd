extends RefCounted
## Occluders (slice G2): one ArrayOccluder3D per 8x8-tile chunk inside one OccluderInstance3D,
## holding a box per solid building (hlod.gd's "solid" entries): the body box from proxies.gd, inset
## 15% of its width on every side and cut to 0.8 of its height, so a box never hides what shows
## past the building's edges. The nodes live under World/Occluders, never under CityView.

const INSET := 0.15
const HEIGHT := 0.8
const FACES := [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]

var root: Node3D
## chunk -> OccluderInstance3D
var chunk_nodes: Dictionary = {}
## chunk -> Array[AABB] (world boxes in the chunk's occluder; test hook)
var chunk_boxes: Dictionary = {}


func setup(p_root: Node3D) -> void:
	root = p_root


## The occluder box for a body box: inset in x and z, from its base up to HEIGHT of it.
static func shrink(body: AABB) -> AABB:
	var inset := Vector3(body.size.x * INSET, 0.0, body.size.z * INSET)
	return AABB(body.position + inset, Vector3(body.size.x - 2.0 * inset.x, body.size.y * HEIGHT, body.size.z - 2.0 * inset.z))


## Rebuilds chunk c's occluder from hlod's cached tile entries.
func rebuild_chunk(c: Vector2i, hlod: RefCounted) -> void:
	var boxes: Array[AABB] = []
	for i: int in (hlod.chunk_tiles.get(c, {}) as Dictionary).keys():
		var e: Dictionary = hlod.tiles[i]
		if bool(e["solid"]) and e.has("body"):
			var b := shrink(e["body"] as AABB)
			if b.size.x > 0.0 and b.size.y > 0.0 and b.size.z > 0.0:
				boxes.append(b)
	var oi: OccluderInstance3D = chunk_nodes.get(c, null)
	if boxes.is_empty():
		if oi != null:
			oi.queue_free()
			chunk_nodes.erase(c)
		chunk_boxes.erase(c)
		return
	var pts := PackedVector3Array()
	var idx := PackedInt32Array()
	for b: AABB in boxes:
		var o := pts.size()
		for k in range(8):
			pts.append(b.get_endpoint(k))
		for q: Array in FACES:
			idx.append_array([o + q[0], o + q[1], o + q[2], o + q[0], o + q[2], o + q[3]])
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(pts, idx)
	if oi == null:
		oi = OccluderInstance3D.new()
		oi.name = "Occluder_%d_%d" % [c.x, c.y]
		root.add_child(oi)
		chunk_nodes[c] = oi
	oi.occluder = occ
	chunk_boxes[c] = boxes


## Shows or hides every occluder.
func set_visible(on: bool) -> void:
	for oi: OccluderInstance3D in chunk_nodes.values():
		if is_instance_valid(oi):
			oi.visible = on


## Number of occluder boxes in every chunk.
func box_count() -> int:
	var n := 0
	for b: Array in chunk_boxes.values():
		n += b.size()
	return n


func clear() -> void:
	for oi: OccluderInstance3D in chunk_nodes.values():
		if is_instance_valid(oi):
			oi.queue_free()
	chunk_nodes.clear()
	chunk_boxes.clear()
