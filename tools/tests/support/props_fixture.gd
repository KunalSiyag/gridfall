extends RefCounted
## The street-props fixture shared by the prop tests (fp_prop_collision_test,
## fp_fallen_props_test): the grown fixture city in fp mode with the traffic, streetscape and
## props features attached, the walkers cleared and the props feature left unstepped for the
## test to drive -- plus the knockable pick and the props-tick settle every knock scenario
## needs. Call make() from the test's _init.

const K := preload("res://tools/tests/fp_kit.gd")
const F := preload("res://tools/tests/support/city_fixtures.gd")
const PF := preload("res://scripts/fp/props/props_feature.gd")
const CK := preload("res://scripts/world/construction_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

## Resting is guaranteed within the tumble's MAX_LIFE (8 s); this covers it with room.
const SETTLE_TICKS := 720


## Builds the fixture: {"ctx", "tr" (traffic), "f" (props)} -- f null when a feature is missing;
## the caller checks and finishes its run. opts: "tee"/"site" also grow a tee with its stop sign
## and an open construction site (needed before the view enters fp mode), "jcb" enables the
## backhoe feature.
static func make(root: Node, opts: Dictionary = {}) -> Dictionary:
	FeatureFlags.set_override("street_clutter", true)
	FeatureFlags.set_override("prop_bumps", true)
	if opts.get("jcb", false):
		FeatureFlags.set_override("jcb", true)
	var ctx: FpContext = K.make_ctx(root, {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	F.ensure_cross(ctx.sim)
	if opts.get("tee", false):
		F.ensure_tee(ctx.sim)
	if opts.get("site", false):
		F.ensure_site(ctx.sim)
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	var tr := K.make_feature(ctx, "traffic")
	K.make_feature(ctx, "streetscape")
	var f := K.make_feature(ctx, "props")
	if tr != null and f != null:
		tr.set("auto_step", false)
		tr.set("ambient_enabled", false)
		f.set_process(false)
		quiet(tr)
		ctx.collision.rebuild_all()
	return {"ctx": ctx, "tr": tr, "f": f}


## Clears the walkers so none wanders through a measurement.
static func quiet(tr: FpFeature) -> void:
	var wk = tr.get("walkers")
	for w in wk.walkers.duplicate():
		wk.remove(w)


## The first standing knockable placement (a kind that gives way at up to mps) whose tile
## passes ok(tile, holder) -- no filter when the callable is invalid:
## {"kind", "tile", "slot", "spot" (world)}.
static func pick_knockable(ctx: FpContext, mps: float, ok: Callable = Callable()) -> Dictionary:
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var placed: Array = ctx.view.street_placements(i)
		for e: Variant in holder.get_meta("colliders", []):
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = e
			if not d.has("slot") or bool(d.get("down", false)):
				continue
			var slot := int(d["slot"])
			if slot < 0 or slot >= placed.size():
				continue
			var kind := str(placed[slot][0])
			if not PF.KINDS.has(kind) or float(PF.KINDS[kind][1]) > mps:
				continue
			if ok.is_valid() and not ok.call(i, holder):
				continue
			return {"kind": kind, "tile": i, "slot": slot, "spot": holder.to_global(d["pos"])}
	return {}


## Steps the props feature's own tick until the knocked prop of tile/slot rests and writes its
## lying box: its `down` entry once written, {} when it never settles.
static func settle(f: FpFeature, tile: int, slot: int) -> Dictionary:
	for _k in range(SETTLE_TICKS):
		f.call("_process", 1.0 / 60.0)
		for e: Dictionary in f.get("down"):
			if int(e["tile"]) == tile and int(e["slot"]) == slot:
				if e.has("fallen_tile"):
					return e
				break
	return {}


## The lying box the props feature wrote for the knocked prop of tile/slot, read back from the
## colliders meta (the channel CollisionWorld reads), in world space; empty AABB when none.
static func lying_box(ctx: FpContext, tile: int, slot: int) -> AABB:
	var holder: Node3D = ctx.view.tile_holder(tile)
	if holder == null:
		return AABB()
	var id := "%d:%d" % [tile, slot]
	for c: Variant in holder.get_meta("colliders", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = c
		if str(d.get("kind", "")) != "fallen" or str(d.get("id", "")) != id:
			continue
		return holder.transform * CK.collider_aabb(d)
	return AABB()


# ------------------------------------------------------------------ shared reads


## The slot's standing collider entry from the holder meta, {} when it has none (walkable):
## the channel CollisionWorld reads.
static func entry_of(holder: Node3D, slot: int) -> Dictionary:
	for e: Variant in holder.get_meta("colliders", []):
		if (
			typeof(e) == TYPE_DICTIONARY
			and int((e as Dictionary).get("slot", -1)) == slot
			and not bool((e as Dictionary).get("down", false))
		):
			return e
	return {}


## The tile's kind "signal" collider entries (junctions.gd owns that kind).
static func signal_entries(holder: Node3D) -> Array:
	var out: Array = []
	for e: Variant in holder.get_meta("colliders", []):
		if typeof(e) == TYPE_DICTIONARY and str((e as Dictionary).get("kind", "")) == "signal":
			out.append(e)
	return out


## The traffic feature's reactions, people and walkers, after checking the posed-body extent
## is wired into reactions: {"react", "pe", "wk"}.
static func reactions_wired(fails: Array[String], tr) -> Dictionary:
	var react = tr.get("reactions")
	var pe = tr.get("people")
	var wk = tr.get("walkers")
	K.check(
		fails,
		(react.get("body_extent") as Callable).is_valid(),
		"fixture: the posed-body extent is wired into reactions"
	)
	return {"react": react, "pe": pe, "wk": wk}


## Every vertex a node's MeshInstance3D children draw, in world space (the drawn sweeps).
static func drawn_verts(node: Node3D) -> PackedVector3Array:
	var out: PackedVector3Array = []
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			if arr.size() <= Mesh.ARRAY_VERTEX:
				continue
			for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
				out.append(mi.global_transform * v)
	return out
