extends SceneTree
## Deterministic, windowed proof of the backhoe loader's arm (the backhoe_arm flag): the rig nodes
## in the real full model, the boom raising, the bucket curling, and a scoop over a construction
## site growing the dirt pile. Run with GRIDFALL_OFFLINE=1, GRIDFALL_NEW_CITY=1 and an isolated
## XDG_DATA_HOME; images go to --output=<absolute directory>. The bench (context, features,
## stepping, shots) is tools/proof_kit.gd; only the parked machine, the site and the framings are
## staged here, the hero driving the machine through drive._process and the input actions.

const KIT := preload("res://tools/proof_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")

var kit: KIT
var _aim: Vector3 = Vector3.ZERO
var _aiming: bool = false


func _init() -> void:
	await process_frame
	kit = KIT.new()
	kit.tag = "BACKHOE_PROOF"
	kit.bench(self, "/tmp/gf-r3-backhoe-proof")
	kit.per_frame = _aim_frame
	kit.quiet_walkers()
	await _arm()
	kit.finish()


## The bench's per-frame hook: hold the shot camera on the spot while it is aiming.
func _aim_frame() -> void:
	if _aiming:
		_frame(_aim)


func _arm() -> void:
	var amb: Object = kit.traffic.get("ambient")
	var m: int = kit.traffic.call("jcb_model")
	if m < 0:
		kit.fail("the backhoe model is loaded")
		return
	amb.set("jcb_in", 1)
	amb.set("jcb_model", func() -> int: return m)
	amb.call("fill_parking")
	var backhoe: VH.Car = null
	for c: VH.Car in kit.cars():
		if c.label == "a backhoe" and c.slot_tile >= 0:
			backhoe = c
	if backhoe == null:
		kit.fail("a backhoe parked at the kerb")
		return
	kit.beside(backhoe)
	if not bool(kit.drive.call("enter")):
		kit.fail("the hero gets in")
		return
	# The full model loads in the background: step until its node is there.
	var node: Node3D = await kit.load_model()
	if node == null:
		kit.fail("the full model is loaded")
		return
	if node.find_child("Arm_Boom", true, false) == null:
		kit.fail("the full model carries the rig nodes")
		return
	# The boom swings out behind the machine: frame that end, from its off side and above.
	_aiming = true
	_aim = _behind(1.4) + Vector3.UP * 1.3 * WS.M
	await kit.settle(40)
	await kit.shot("arm_stowed")

	# Y raises the boom; I curls the bucket in.
	await kit.hold("backhoe_arm_up", 40)
	await kit.shot("arm_boom_up")
	await kit.hold("backhoe_bucket_curl", 26)
	await kit.shot("arm_bucket_curl")
	await kit.hold("backhoe_arm_down", 40)
	await kit.hold("backhoe_bucket_dump", 26)
	await kit.shot("arm_stowed_again")

	# A scoop over a construction site: the arm low, dump then curl, and the pile grows in front.
	var spot := _front(2.2)
	var tile := kit.ctx.collision.tile_at(spot)
	var injected := not kit.ctx.sim.sites.has(tile)
	if injected:
		kit.ctx.sim.sites[tile] = _site(tile)
	await kit.hold("backhoe_bucket_dump", 40)
	await kit.hold("backhoe_bucket_curl", 170)
	await kit.shot("arm_dig_pile")
	var arm: Object = kit.drive.get("arm")
	var pile := float(arm.get("pile"))
	if pile <= 1.0:
		kit.fail("the scoop grew the dirt pile (%.1f)" % pile)
	var dirt := (node.get_parent() as Node).find_child("DirtPile", true, false) as MeshInstance3D
	if dirt == null or dirt.global_position.distance_to(spot) > 3.0 * WS.M:
		kit.fail("the pile stands in front of the machine")
	if injected:
		kit.ctx.sim.sites.erase(tile)
	# Frame the pile itself for the last shot.
	_aim = spot + Vector3.UP * 0.4 * WS.M
	await kit.settle(14)
	await kit.shot("arm_pile_close")


## A construction-site record for tile i shaped like the sim's own (city_sim._start_site), so the
## view can read it while the scoop runs (the sim is paused; only the dig cares).
func _site(i: int) -> Dictionary:
	return {
		"id": 9002,
		"i": i,
		"x": D.tx(i),
		"y": D.ty(i),
		"type": "build",
		"plan": "build",
		"owner": -1,
		"from_kind": 0,
		"from_level": 0,
		"target_kind": 1,
		"target_level": 1,
		"stages": (D.SITE_STAGES["build"] as Array).duplicate(),
		"stage": 0,
		"progress": 0.0,
		"stage_work": 100.0,
		"crew": {},
		"label": "proof site",
		"start_tick": 0,
		"rate": 0.0,
		"tick_work": 0.0,
	}


## A point this far ahead of the machine, at ground level.
func _front(ahead: float) -> Vector3:
	var c := kit.car()
	var f := OBB.heading(c.yaw)
	var p := c.pos + Vector3(f.x, 0.0, f.y) * ahead * WS.M
	return Vector3(p.x, kit.ctx.collision.walk_height(Vector3(p.x, 0.0, p.z)), p.z)


## A point this far behind the machine (where the arm hangs), at ground level.
func _behind(back: float) -> Vector3:
	var c := kit.car()
	var f := OBB.heading(c.yaw)
	var p := c.pos - Vector3(f.x, 0.0, f.y) * back * WS.M
	return Vector3(p.x, kit.ctx.collision.walk_height(Vector3(p.x, 0.0, p.z)), p.z)


## Puts the shot camera off the machine's side, looking at spot.
func _frame(spot: Vector3) -> void:
	var cam: Camera3D = kit.ctx.player.camera
	if cam == null:
		return
	var c := kit.car()
	var f := OBB.heading(c.yaw)
	var side := Vector2(f.y, -f.x)
	var at := spot + Vector3(side.x, 0.0, side.y) * 4.6 * WS.M + Vector3.UP * 2.0 * WS.M
	cam.position = at
	cam.look_at(spot)
	cam.fov = 42.0
	cam.make_current()
