extends SceneTree
## Deterministic, windowed proof of the ambient bicycle lamps (round 3): a rank of cyclists held
## on a straight road at night — the nearest on its full model, its small head and tail lenses lit
## through the same per-instance overrides as a car's lamps, the ones past the full-model range
## drawn through the merged far LOD whose lamp vertices glow from the lod1's emissive lens
## materials — and the same rank by day, all dark. Run windowed with GRIDFALL_OFFLINE=1,
## GRIDFALL_NEW_CITY=1 and an isolated XDG_DATA_HOME; images go to --output=<absolute directory>.
## The bench (context, features, stepping, shots, the staged road) is tools/proof_kit.gd; the
## held rank, the held sky and the framings are this proof's own.

const KIT := preload("res://tools/proof_kit.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const RD := preload("res://scripts/fp/traffic/render.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
## The held clock: well past dusk (the sky's night at 1) and noon (at 0).
const NIGHT_HOUR := 23.0
const DAY_HOUR := 12.0
## Cyclists staged one per tile down the run (the bench's road is 3+ tiles long).
const RANK := 5

var kit: KIT
var _bikes: Array = []


func _init() -> void:
	await process_frame
	kit = KIT.new()
	kit.tag = "BIKE_LAMP_PROOF"
	kit.bench(self, "/tmp/gf-r3-bike-lamp-proof")
	kit.traffic.set("ambient_enabled", false)
	if not kit.road():
		kit.finish()
		return
	_rank()
	if _bikes.is_empty():
		kit.finish()
		return
	kit.per_frame = _pin
	kit.beside(_bikes[0])
	_sky(NIGHT_HOUR)
	await kit.settle(60)
	_lamp_check(true)
	_frame("tail")
	await kit.shot("bike_lamps_night")
	_frame("near")
	await kit.shot("bike_lamps_night_near")
	_sky(DAY_HOUR)
	await kit.settle(60)
	_lamp_check(false)
	_frame("tail")
	await kit.shot("bike_lamps_day")
	kit.finish()


## The rank: one standing cyclist per lane down the straight run, all facing the same way. The
## per-frame pin holds them there (a free lane bike would ride off during the settling frames).
func _rank() -> void:
	var m: int = kit.traffic.call("bike_model")
	if m < 0:
		kit.fail("the bicycle model is loaded")
		return
	kit.clear_cars()
	kit.quiet_walkers()
	for k in range(mini(RANK, kit.lanes.size())):
		var c := _vh().make("bike", "ambient", kit.traffic.call("dims", m))
		c.model = m
		_vh().place(c, kit.lanes[k], 0.5)
		c.v = 0.0
		_bikes.append(c)


## Holds every cyclist at its staged spot (runs inside the bench's settle, after the step).
func _pin() -> void:
	for k in range(_bikes.size()):
		var c: VH.Car = _bikes[k]
		_vh().place(c, kit.lanes[k], 0.5)
		c.v = 0.0


## The lamp state against the sky: after dark the near bicycle's lenses are lit through
## per-instance overrides (the imported materials untouched), the rank reaches past the
## full-model range (the merged LOD, where the lamp vertices glow) and the glow is really up;
## by day the imported lamps are back. The far LOD itself carries lamp-flagged vertices.
func _lamp_check(on: bool) -> void:
	var rd: RD = kit.traffic.get("render")
	var glow := float(rd.get("_glow"))
	if (glow > RD.LAMPS_ON) != on:
		kit.fail("the streets' lamp glow follows the sky (%.2f)" % glow)
	var near: VH.Car = _bikes[0]
	if near.lod != 0:
		kit.fail("the near bicycle is drawn in full (lod %d)" % near.lod)
	var node: Node3D = near.node
	if node == null or not node.has_meta("head") or not node.has_meta("tail"):
		kit.fail("the near bicycle carries its lamp lenses")
		return
	if _lenses_lit(node) != on:
		kit.fail("the near bicycle's lamps are %s" % ("on" if on else "off"))
	if not on:
		return
	var far := 0
	for c: VH.Car in _bikes:
		if c.lod >= 1:
			far += 1
	if far < 1:
		kit.fail("the rank reaches past the full-model range (%d far)" % far)
	var flagged := _flagged_lamp_verts(rd)
	if flagged < 16:
		kit.fail("the far LOD's lamp vertices are flagged to glow (%d)" % flagged)


## The node's head and tail lenses both lit through per-instance overrides.
func _lenses_lit(node: Node3D) -> bool:
	var head: Array = node.get_meta("head")
	var tail: Array = node.get_meta("tail")
	return (
		(head[0] as MeshInstance3D).get_surface_override_material(int(head[1])) != null
		and (tail[0] as MeshInstance3D).get_surface_override_material(int(tail[1])) != null
	)


## The lamp vertices flagged to glow (vertex alpha under 0.75) in the bicycle's merged far LOD.
func _flagged_lamp_verts(rd: RD) -> int:
	var out := 0
	for mod in rd.get("models"):
		if not str(mod.get("key")).begins_with(AP.BICYCLE):
			continue
		var mesh: Mesh = mod.get("lod_mesh")
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var raw: Variant = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		for col: Color in raw if raw is PackedColorArray else PackedColorArray():
			if col.a < 0.75:
				out += 1
	return out


## Puts the shot camera on one of the proof's framings: "tail" looks down the rank from behind
## the near cyclist (its tail lamp, and the far bicycles' glow down the road); "near" closes on
## the near bicycle's rear quarter, rider and lit tail lens.
func _frame(aim: String) -> void:
	var cam: Camera3D = kit.ctx.player.camera
	if cam == null:
		return
	var c: VH.Car = _bikes[0]
	var f := OBB.heading(c.yaw)
	var side := Vector2(f.y, -f.x)
	var p := c.pos + Vector3(c.vis_off.x, 0.0, c.vis_off.z)
	var at := p
	var look := p
	match aim:
		"tail":
			at = (
				p
				- Vector3(f.x, 0.0, f.y) * 6.0 * WS.M
				+ Vector3(side.x, 0.0, side.y) * 1.2 * WS.M
				+ Vector3.UP * 1.7 * WS.M
			)
			look = p + Vector3(f.x, 0.0, f.y) * 40.0 * WS.M + Vector3.UP * 0.6 * WS.M
		"near":
			at = (
				p
				- Vector3(f.x, 0.0, f.y) * 2.6 * WS.M
				+ Vector3(side.x, 0.0, side.y) * 1.4 * WS.M
				+ Vector3.UP * 1.1 * WS.M
			)
			look = p + Vector3.UP * 0.75 * WS.M
	cam.position = at
	cam.look_at(look)
	cam.fov = 50.0
	cam.make_current()


## Holds the sky at the given hour, blended fully at once: the bench pauses its clock, and night
## is derived from the hour on every apply, so the hour is what must be held.
func _sky(hour: float) -> void:
	kit.ctx.sky.fixed_hour = hour
	kit.ctx.sky.call("_process", 1.0)


func _vh() -> VH:
	return kit.traffic.get("vehicles")
