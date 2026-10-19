extends RefCounted
## Visibility ranges and far impostors (slice G2). post_pass() classifies every drawn part of a tile
## holder once (building, prop or road), sets its visibility range and shadow casting, and caches
## the list so a preset switch never walks the scene again. Far buildings are drawn as stepped
## mass proxies (proxies.gd) merged into one mesh per 8x8-tile chunk; the impostor shader hides each
## proxy inside the range where its real building is drawn, so the two never overlap.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const PROXIES := preload("res://scripts/fp/render/proxies.gd")
const SHADER := preload("res://scripts/fp/render/impostor.gdshader")
const CHUNK := 8
enum Cls { BUILDING, PROP, ROAD }
## Meshes smaller than this (longest side, world units) never cast shadows (1 m).
const SMALL := 0.05
const PROP_SCENES := ["res://models/real/props/", "res://models/props/"]
## Service kinds drawn as far impostors (open or sparse ones, like parks and wind farms, are not).
const IMPOSTOR_SERVICES := [D.HALL, D.HOSPITAL, D.SCHOOL, D.POLICE, D.FIRE, D.UNIVERSITY, D.TRAIN, D.COAL, D.PUMP, D.SEWAGE, D.STADIUM]
## Closed services that occlude (G2 contract: solid kinds).
const SOLID_SERVICES := [D.HALL, D.HOSPITAL, D.SCHOOL, D.POLICE, D.FIRE, D.UNIVERSITY, D.TRAIN]

var view: CityView
var sim: CitySim
var root: Node3D
var proxies: RefCounted = PROXIES.new()
var material: ShaderMaterial
## Visibility ranges in world units after the preset multiplier.
var vis_building: float = WS.VIS_BUILDING
var vis_prop: float = WS.VIS_PROP
## tile index -> entry {"holder", "gis": Array of GeometryInstance3D, "cls": PackedByteArray,
## "chunk": Vector2i, "path", "xf": Transform3D (model to world), "center": Vector3 (the engine's
## range point of the main mesh), "impostor": bool, "solid": bool}
var tiles: Dictionary = {}
## chunk -> {tile index: true}
var chunk_tiles: Dictionary = {}
## chunk -> MeshInstance3D
var chunk_nodes: Dictionary = {}
## Test hooks: holders walked by post_pass, and chunk meshes built.
var walks: int = 0
var builds: int = 0


func setup(p_view: CityView, p_sim: CitySim, p_root: Node3D) -> void:
	view = p_view
	sim = p_sim
	root = p_root
	material = ShaderMaterial.new()
	material.shader = SHADER
	set_ranges(vis_building, vis_prop)


## Sets the switch distances used from now on (cached parts are re-ranged by apply_ranges).
func set_ranges(building: float, prop: float) -> void:
	vis_building = building
	vis_prop = prop
	material.set_shader_parameter("range_sq", building * building)
	for c: Vector2i in chunk_nodes.keys():
		_set_chunk_begin(chunk_nodes[c] as MeshInstance3D)


static func chunk_of(i: int) -> Vector2i:
	return Vector2i(floori(float(D.tx(i)) / CHUNK), floori(float(D.ty(i)) / CHUNK))


## Classifies and ranges every drawn part of tile i's holder; returns the chunk that changed or
## Vector2i(-9999, -9999) when the tile is not part of any chunk.
func post_pass(i: int, holder: Node3D) -> Vector2i:
	drop(i)
	if holder == null or not is_instance_valid(holder) or not holder.is_inside_tree():
		return chunk_of(i)
	walks += 1
	var site := holder.get_node_or_null("Site")
	var road := sim.kind[i] == D.ROAD
	var gis: Array = []
	var cls := PackedByteArray()
	for n in holder.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if site != null and (gi == site or site.is_ancestor_of(gi)):
			continue
		if not gi.has_meta("g2_vis") and (gi.visibility_range_end != 0.0 or gi.visibility_range_begin != 0.0):
			continue
		var c := Cls.PROP if _is_prop(gi, holder) else (Cls.ROAD if road else Cls.BUILDING)
		gis.append(gi)
		cls.append(c)
		gi.set_meta("g2_vis", true)
		if c == Cls.PROP or _longest(gi) < SMALL:
			if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and not gi.has_meta("g2_shadow"):
				gi.set_meta("g2_shadow", gi.cast_shadow)
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var e := {"holder": holder, "gis": gis, "cls": cls, "chunk": chunk_of(i), "path": "", "impostor": false, "solid": false}
	apply_ranges(e)
	_proxy_info(i, holder, e)
	tiles[i] = e
	var ch := e["chunk"] as Vector2i
	if not chunk_tiles.has(ch):
		chunk_tiles[ch] = {}
	(chunk_tiles[ch] as Dictionary)[i] = true
	return ch


## Forgets tile i (its holder was replaced or cleared); returns its chunk.
func drop(i: int) -> Vector2i:
	var c := chunk_of(i)
	if tiles.has(i):
		tiles.erase(i)
		if chunk_tiles.has(c):
			(chunk_tiles[c] as Dictionary).erase(i)
	return c


## Visibility ranges of one cached entry at the current distances.
func apply_ranges(e: Dictionary) -> void:
	var gis: Array = e["gis"]
	var cls: PackedByteArray = e["cls"]
	for k in range(gis.size()):
		if not is_instance_valid(gis[k]):
			continue
		var gi := gis[k] as GeometryInstance3D
		gi.visibility_range_end = vis_prop if cls[k] == Cls.PROP else vis_building
		# No hysteresis margin: the impostor shader switches at exactly this distance.
		gi.visibility_range_end_margin = 0.0
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


## Restores what post_pass changed on one entry: no range, shadows as authored, no g2 metas.
static func restore(e: Dictionary) -> void:
	for o: Variant in e["gis"]:
		if not is_instance_valid(o):
			continue
		var gi := o as GeometryInstance3D
		gi.visibility_range_end = 0.0
		gi.visibility_range_end_margin = 0.0
		if gi.has_meta("g2_shadow"):
			gi.cast_shadow = int(gi.get_meta("g2_shadow")) as GeometryInstance3D.ShadowCastingSetting
			gi.remove_meta("g2_shadow")
		gi.remove_meta("g2_vis")


## Rebuilds the merged impostor mesh of chunk c from the cached entries.
func rebuild_chunk(c: Vector2i) -> void:
	builds += 1
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var centers: Array[Vector3] = []
	for i: int in (chunk_tiles.get(c, {}) as Dictionary).keys():
		var e: Dictionary = tiles[i]
		if not bool(e["impostor"]):
			continue
		var p: Dictionary = proxies.proxy(str(e["path"]))
		var pv: PackedVector3Array = p["verts"]
		if pv.is_empty():
			continue
		var xf: Transform3D = e["xf"]
		var center: Vector3 = e["center"]
		v.append_array(xf * pv)
		nrm.append_array(Transform3D(xf.basis.orthonormalized(), Vector3.ZERO) * (p["normals"] as PackedVector3Array))
		col.append_array(p["colors"])
		var a := PackedVector2Array()
		a.resize(pv.size())
		a.fill(Vector2(float(p["win"]), center.y))
		uv.append_array(a)
		a.fill(Vector2(center.x, center.z))
		uv2.append_array(a)
		centers.append(center)
	var mi: MeshInstance3D = chunk_nodes.get(c, null)
	if v.is_empty():
		if mi != null:
			mi.queue_free()
			chunk_nodes.erase(c)
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "Impostor_%d_%d" % [c.x, c.y]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = material
		root.add_child(mi)
		chunk_nodes[c] = mi
	mi.mesh = mesh
	# The engine measures ranges from the AABB centre: farthest building centre from it.
	var mid := mesh.get_aabb().get_center()
	var reach := 0.0
	for p: Vector3 in centers:
		reach = maxf(reach, p.distance_to(mid))
	mi.set_meta("reach", reach)
	_set_chunk_begin(mi)


## The chunk mesh is skipped entirely while every building in it is within range.
func _set_chunk_begin(mi: MeshInstance3D) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	mi.visibility_range_begin = maxf(0.0, vis_building - float(mi.get_meta("reach", 0.0)))
	mi.visibility_range_begin_margin = 0.0


## Shows or hides every impostor.
func set_visible(on: bool) -> void:
	for mi: MeshInstance3D in chunk_nodes.values():
		if is_instance_valid(mi):
			mi.visible = on


## Frees every impostor and forgets every tile.
func clear() -> void:
	for mi: MeshInstance3D in chunk_nodes.values():
		if is_instance_valid(mi):
			mi.queue_free()
	chunk_nodes.clear()
	tiles.clear()
	chunk_tiles.clear()


## Fills path, xf, center, impostor and solid for tile i.
func _proxy_info(i: int, holder: Node3D, e: Dictionary) -> void:
	if not holder.has_meta("building_path"):
		return
	var path := str(holder.get_meta("building_path"))
	var k := sim.kind[i]
	var zone := D.is_zone(k) and sim.level[i] >= 1
	if path.is_empty() or not (zone or k in IMPOSTOR_SERVICES):
		return
	var model: Node3D = null
	for ch in holder.get_children():
		if ch is Node3D and ch.scene_file_path == path:
			model = ch
			break
	if model == null:
		return
	var p: Dictionary = proxies.proxy(path, model)
	if (p["verts"] as PackedVector3Array).is_empty():
		return
	var xf: Transform3D = holder.global_transform * (holder.get_meta("building_xform") as Transform3D)
	e["path"] = path
	e["xf"] = xf
	e["center"] = _range_point(model, xf)
	e["impostor"] = true
	e["solid"] = (k == D.ZONE_R and sim.level[i] >= 2) or ((k == D.ZONE_C or k == D.ZONE_I) and sim.level[i] >= 1) or k in SOLID_SERVICES
	e["body"] = xf * (p["body"] as AABB)


## World point the engine measures the main mesh's visibility range from (its AABB centre), using
## the final model transform (not a grow tween in progress).
static func _range_point(model: Node3D, xf: Transform3D) -> Vector3:
	var best: MeshInstance3D = null
	var best_vol := -1.0
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or PROXIES._skipped(str(mi.name)):
			continue
		var vol := mi.get_aabb().get_volume()
		if vol > best_vol:
			best_vol = vol
			best = mi
	if best == null:
		return xf.origin
	return (xf * PROXIES._relative(model, best) * best.get_aabb()).get_center()


static func _is_prop(gi: Node, holder: Node) -> bool:
	var n := gi
	while n != null and n != holder:
		if n.has_meta("prop"):
			return true
		var sp := n.scene_file_path
		if not sp.is_empty():
			for pre: String in PROP_SCENES:
				if sp.begins_with(pre):
					return true
		n = n.get_parent()
	return false


static func _longest(gi: GeometryInstance3D) -> float:
	var a := gi.global_transform * gi.get_aabb()
	return maxf(a.size.x, maxf(a.size.y, a.size.z))
