extends SceneTree
## Every street-dressed class draws solid: what its model draws in the body band (a mover's
## height span) its collider must cover, so no body on foot or in a car ends up standing inside
## visible geometry. The junction plinth was one instance of the class; this sweeps them all,
## vertex by vertex, at up to SAMPLES placements per class, against the colliders-meta entry of
## the slot (the channel CollisionWorld reads). Two overhangs stay overhangs by design and are
## measured against their own lower band instead: the tree crown (its leaves NEAR_FADE near the
## camera; only the trunk is solid) and the signal heads above the hero's height.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FIX := preload("res://tools/tests/support/props_fixture.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
## Drawn geometry above this (u) is overhang on purpose: lamp arms, crowns, signal heads.
const BODY_BAND := 2.0 * WS.M
## The tree crown's lowest drawn leaf (u): the trunk-only cylinder must still cover everything
## drawn below it.
const CROWN_BOTTOM := 1.4 * WS.M
## Up to this many placements per class are swept.
const SAMPLES := 3
## Drawn geometry within this (u) of its collider counts covered (merged low-poly noise).
const NOISE := 0.002 * WS.M

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature


func _init() -> void:
	await process_frame
	var made := FIX.make(get_root(), {"tee": true, "site": true, "jcb": true})
	ctx = made["ctx"]
	tr = made["tr"]
	if tr == null:
		K.check(fails, false, "fixture: the traffic feature is registered")
		K.finish(self, "FP_PROP_COVERAGE_TEST", fails)
		return
	_check_classes()
	_check_posts()
	K.finish(self, "FP_PROP_COVERAGE_TEST", fails)


# ------------------------------------------------------------------ street classes


## Sweeps every dressed class and checks the drawn parts against the slot's collider.
func _check_classes() -> void:
	var kinds: Dictionary = _sweep({"tree": CROWN_BOTTOM})
	var names: Array = kinds.keys()
	names.sort()
	K.check(
		fails,
		names.size() >= 10,
		"fixture: the street dresses at least ten classes with colliders (%d)" % names.size()
	)
	for kind: String in names:
		var d: Dictionary = kinds[kind]
		K.check(
			fails,
			float(d["under"]) <= NOISE,
			(
				"no drawn %s pokes outside its %s collider (%d swept, worst %.0f mm at y %.2f m)"
				% [
					kind,
					str(d["shape"]),
					int(d["n"]),
					float(d["under"]) / WS.M * 1000.0,
					float(d["worst_y"]) / WS.M
				]
			)
		)


## Every placement's class -> the worst drawn vertex outside its slot's collider entry
## ({"n", "under", "worst_y", "shape"}), swept under band[kind] (BODY_BAND without an entry).
## The tree is swept under CROWN_BOTTOM: its crown overhangs on purpose, its trunk does not.
func _sweep(band: Dictionary) -> Dictionary:
	var kinds: Dictionary = {}
	var seen := {}
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var placed: Array = ctx.view.street_placements(i)
		for slot in range(placed.size()):
			var kind := str(placed[slot][0])
			if int(seen.get(kind, 0)) >= SAMPLES:
				continue
			var entry := _entry_of(holder, int(slot))
			if entry.is_empty():
				continue
			var kit: Dictionary = ctx.view.street_kit(kind)
			if kit.is_empty():
				continue
			seen[kind] = int(seen.get(kind, 0)) + 1
			var res := _worst_of(
				kit, placed[slot][1], entry, holder, float(band.get(kind, BODY_BAND))
			)
			res["shape"] = str(entry.get("shape", "box"))
			_merge(kinds, kind, res)
	return kinds


## The slot's standing collider entry from the holder meta, {} when it has none (walkable).
func _entry_of(holder: Node3D, slot: int) -> Dictionary:
	for e: Variant in holder.get_meta("colliders", []):
		if (
			typeof(e) == TYPE_DICTIONARY
			and int((e as Dictionary).get("slot", -1)) == slot
			and not bool((e as Dictionary).get("down", false))
		):
			return e
	return {}


## The kit's drawn vertices at placement xf vs its collider entry, under band_top:
## {"under", "worst_y"}.
func _worst_of(
	kit: Dictionary, xf: Transform3D, entry: Dictionary, holder: Node3D, band_top: float
) -> Dictionary:
	var under := 0.0
	var worst_y := 0.0
	for part: Dictionary in kit["parts"]:
		var mesh: Mesh = part["mesh"]
		var pxf: Transform3D = part["xform"]
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			if arr.size() <= Mesh.ARRAY_VERTEX:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for v in verts:
				var w: Vector3 = xf * (pxf * v)
				var u := _under(w, entry, holder, band_top)
				if is_inf(u):
					continue
				if u > under:
					under = u
					worst_y = w.y
	return {"under": under, "worst_y": worst_y}


# ------------------------------------------------------------------ junction posts


## The junction poles (cross signals and tee signs) draw solid too: everything they draw
## between the steppable zone and the hero's height must be covered by the tile's signal
## entries. Above the hero (the heads at 1.95 m) and below STEP_HEIGHT (the plinth's base,
## which ground bodies step onto) are outside every mover's band on purpose.
func _check_posts() -> void:
	var jn = tr.get("junctions")
	var worst := 0.0
	var worst_y := 0.0
	var n := 0
	if jn == null:
		K.check(fails, false, "fixture: the traffic feature builds junction poles")
		return
	for i: int in (jn.props as Dictionary).keys():
		var p: Dictionary = (jn.props as Dictionary)[i]
		if not p.has("node") or not is_instance_valid(p["node"]):
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var entries := _signal_entries(holder)
		if entries.is_empty():
			continue
		n += 1
		for mi: MeshInstance3D in (p["node"] as Node3D).find_children(
			"*", "MeshInstance3D", true, false
		):
			for s in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(s)
				if arr.size() <= Mesh.ARRAY_VERTEX:
					continue
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				for v in verts:
					var w: Vector3 = mi.global_transform * v
					if w.y < WS.STEP_HEIGHT or w.y > WS.PLAYER_HEIGHT:
						continue
					var u := _under_any(w, entries, holder, WS.PLAYER_HEIGHT)
					if u > worst:
						worst = u
						worst_y = w.y
	K.check(fails, n >= 4, "fixture: at least four junction poles dressed (%d)" % n)
	K.check(
		fails,
		worst <= NOISE,
		(
			(
				"no drawn junction pole pokes outside its signal colliders below head height "
				+ "(%d poles, worst %.0f mm at y %.2f m)"
			)
			% [n, worst / WS.M * 1000.0, worst_y / WS.M]
		)
	)


## The tile's kind "signal" collider entries (junctions.gd owns that kind).
func _signal_entries(holder: Node3D) -> Array:
	var out: Array = []
	for e: Variant in holder.get_meta("colliders", []):
		if typeof(e) == TYPE_DICTIONARY and str((e as Dictionary).get("kind", "")) == "signal":
			out.append(e)
	return out


# ------------------------------------------------------------------ margins


## How far w sits outside entry (u), INF when w flies above band_top (overhang is not
## under-coverage). Boxes are measured in their yaw'd frame, cylinders about their axis.
func _under(w: Vector3, entry: Dictionary, holder: Node3D, band_top: float) -> float:
	if str(entry.get("shape", "box")) == "cyl":
		if w.y > band_top:
			return INF
		var p: Vector3 = holder.transform * (entry.get("pos", Vector3.ZERO) as Vector3)
		if w.y > p.y + float(entry.get("h", 0.0)):
			return 0.0
		var r := float(entry.get("r", 0.0))
		return maxf(0.0, Vector2(w.x - p.x, w.z - p.z).length() - r)
	var local := holder.transform.affine_inverse() * w
	var size: Vector3 = entry["size"]
	var lpos: Vector3 = entry.get("pos", Vector3.ZERO)
	var yaw := float(entry.get("yaw", 0.0))
	var q := Transform3D(Basis(Vector3.UP, yaw), lpos).affine_inverse() * local
	if q.y > band_top - lpos.y:
		return INF
	if q.y < 0.0 or q.y > size.y:
		return 0.0
	var dx := maxf(0.0, absf(q.x) - size.x * 0.5)
	var dz := maxf(0.0, absf(q.z) - size.z * 0.5)
	return sqrt(dx * dx + dz * dz)


## How far w sits outside every entry of entries (u): the nearest one wins.
func _under_any(w: Vector3, entries: Array, holder: Node3D, band_top: float) -> float:
	var under := INF
	for e: Variant in entries:
		under = minf(under, _under(w, e, holder, band_top))
	return 0.0 if is_inf(under) else under


func _merge(kinds: Dictionary, kind: String, res: Dictionary) -> void:
	var shape := str(res.get("shape", ""))
	var d: Dictionary = kinds.get_or_add(
		kind, {"n": 0, "under": 0.0, "worst_y": 0.0, "shape": shape}
	)
	d["n"] = int(d["n"]) + 1
	if float(res["under"]) > float(d["under"]):
		d["under"] = float(res["under"])
		d["worst_y"] = float(res["worst_y"])
