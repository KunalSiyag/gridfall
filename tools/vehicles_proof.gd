extends SceneTree
## Deterministic, windowed proofs of round 3's motors: the hero riding the bicycle (the bike_ride
## flag; feet on the pedals, hands on the grips) and the bus, truck and garbage truck under the
## heavy_motors flag (each driving on its own heavy profile, the HUD live at the wheel). Run
## windowed with GRIDFALL_OFFLINE=1, GRIDFALL_NEW_CITY=1 and an isolated XDG_DATA_HOME; images go
## to --output=<absolute directory>. The bench (context, features, stepping, shots, the staged
## road and the pull-up) is tools/proof_kit.gd; the hero rides and drives through drive._process
## and the input actions, and only the staged vehicles, the empty road and the framings are this
## proof's own.

const KIT := preload("res://tools/proof_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")
const SHOVES := preload("res://scripts/fp/traffic/shoves.gd")

var kit: KIT
## The live framing: "" leaves the player's own camera, else a named one recomputed every frame.
var _aim: String = ""
var _aim_car: VH.Car


func _init() -> void:
	await process_frame
	kit = KIT.new()
	kit.tag = "VEHICLES_PROOF"
	kit.bench(self, "/tmp/gf-r3-vehicles-proof")
	kit.per_frame = _live_frame
	if not kit.road():
		kit.finish()
		return
	await _ride_bike()
	for body: String in ["bus", "truck", "garbage_truck"]:
		await _drive_heavy(body)
	kit.finish()


## The hero rides the bicycle away from a standing start: the crank really turns under their feet,
## the drive state and the seat pose know it is a bicycle, and the side, pedal and grip framings
## all come from the moving machine.
func _ride_bike() -> void:
	var m: int = kit.traffic.call("bike_model")
	if m < 0:
		kit.fail("the bicycle model is loaded")
		return
	_clear()
	var c := _vh().make("bike", "ambient", kit.traffic.call("dims", m))
	c.model = m
	_vh().place(c, kit.lanes[0], 0.35)
	c.v = 0.0
	kit.beside(c)
	if not bool(kit.drive.call("enter")):
		kit.fail("the hero gets on the bicycle")
		return
	_aim_car = kit.car()
	var node: Node3D = await kit.load_model()
	if node == null:
		kit.fail("the bicycle's full model is loaded")
		return
	if not bool(kit.drive.get("bike")):
		kit.fail("the drive state knows it is a bicycle")
	var crank0 := float(node.get_meta("crank_th", 0.0))
	Input.action_press("drive_throttle")
	_aim = "bike_side"
	await kit.settle(90)
	await kit.shot("bike_side")
	var turned := absf(float(node.get_meta("crank_th", 0.0)) - crank0)
	if turned < 0.7:
		kit.fail("the crank turns under the hero's feet (%.2f rad)" % turned)
	_aim = "bike_feet"
	await kit.settle(10)
	await kit.shot("bike_feet")
	_aim = "bike_grips"
	await kit.settle(10)
	await kit.shot("bike_grips")
	var pose: Object = kit.drive.get("pose")
	if not bool(pose.get("_bike")):
		kit.fail("the seat pose knows it is a bicycle (grips, no roof)")
	await _stop_and_leave()
	_clear()


## The hero drives one of the heavy bodies (the heavy_motors flag): in by its own name, out on
## its heavy profile, gaining speed down the empty road, framed on the move and in profile.
func _drive_heavy(body: String) -> void:
	var m: int = kit.traffic.call("vehicle_model", body)
	if m < 0:
		kit.fail("the %s model is loaded" % body)
		return
	_clear()
	var dims: Vector3 = kit.traffic.call("dims", m)
	var c := _vh().make(body, _role(body), dims)
	c.model = m
	_vh().place(c, kit.lanes[0], 0.35)
	c.v = 0.0
	kit.beside(c)
	if not bool(kit.drive.call("enter")):
		kit.fail("the hero gets in the %s" % body)
		return
	_aim_car = kit.car()
	var node: Node3D = await kit.load_model()
	if node == null:
		kit.fail("the %s's full model is loaded" % body)
		return
	var dm: MODEL = kit.drive.get("model")
	var prof: Dictionary = kit.traffic.call("drive_profile", _car().id)
	if absf(dm.gain - float(prof.get("gain", 1.0))) > 1e-6 or dm.gain >= 0.5:
		kit.fail("the %s drives on its heavy profile (gain %.2f)" % [body, dm.gain])
	if SHOVES.mass_of(_car()) < 3.0:
		kit.fail("the %s carries its heavy mass (%.1f)" % [body, SHOVES.mass_of(_car())])
	Input.action_press("drive_throttle")
	_aim = "drive"
	await kit.settle(150)
	await kit.shot(body + "_drive")
	_aim = "side"
	await kit.settle(8)
	await kit.shot(body + "_side")
	await _stop_and_leave()
	_clear()


## The traffic role that goes with each heavy kind.
func _role(body: String) -> String:
	return {"bus": "bus", "truck": "truck", "garbage_truck": "garbage"}[body]


## Lets the vehicle pull up and the hero out (the bench's stop_and_leave), the proof's own shot
## camera let go for it so the player's camera takes the pull-up over.
func _stop_and_leave() -> void:
	_aim = ""
	await kit.stop_and_leave()


## The bench's per-frame hook: the road kept empty of the traffic the running clocks spawn (it
## would cross the shot), and the live framing recomputed while one is picked.
func _live_frame() -> void:
	if _aim.is_empty():
		return
	for c: VH.Car in _vh().cars.duplicate():
		if c != _aim_car:
			_vh().remove(c)
	_frame()


## Every vehicle goes, the player's own included — a clean road, with the hero on foot.
func _clear() -> void:
	kit.clear_cars()
	kit.quiet_walkers()


func _vh() -> VH:
	return kit.traffic.get("vehicles")


func _car() -> VH.Car:
	return kit.car()


## Puts the shot camera on the live framing of the vehicle being driven: its side, close on the
## bike's pedals, over the bike's grips, behind the quarter of a heavy body in motion, or
## broadside.
func _frame() -> void:
	var cam: Camera3D = kit.ctx.player.camera
	if cam == null:
		return
	var c := _aim_car
	var f := OBB.heading(c.yaw)
	var side := Vector2(f.y, -f.x)
	var p := c.pos + Vector3(c.vis_off.x, 0.0, c.vis_off.z)
	var at := p
	var look := p
	var fov := 42.0
	match _aim:
		"bike_side":
			at = p + Vector3(side.x, 0.0, side.y) * 3.6 * WS.M + Vector3.UP * 1.25 * WS.M
			look = p + Vector3.UP * 0.8 * WS.M
			fov = 38.0
		"bike_feet":
			at = p + Vector3(side.x, 0.0, side.y) * 2.1 * WS.M + Vector3.UP * 0.7 * WS.M
			look = p + Vector3(f.x, 0.0, f.y) * 0.2 * WS.M + Vector3.UP * 0.45 * WS.M
			fov = 36.0
		"bike_grips":
			at = (
				p
				+ Vector3(f.x, 0.0, f.y) * 2.6 * WS.M
				+ Vector3(side.x, 0.0, side.y) * 1.5 * WS.M
				+ Vector3.UP * 1.6 * WS.M
			)
			look = p + Vector3.UP * 0.95 * WS.M
			fov = 38.0
		"drive":
			at = (
				p
				- Vector3(f.x, 0.0, f.y) * (c.length * 1.05)
				+ Vector3(side.x, 0.0, side.y) * (c.length * 0.45 + 2.0 * WS.M)
				+ Vector3.UP * 3.4 * WS.M
			)
			look = p + Vector3(f.x, 0.0, f.y) * (c.length * 0.2) + Vector3.UP * 1.4 * WS.M
			fov = 48.0
		"side":
			at = p + Vector3(side.x, 0.0, side.y) * (c.length * 0.9) + Vector3.UP * 2.6 * WS.M
			look = p + Vector3.UP * 1.0 * WS.M
			fov = 40.0
	cam.position = at
	cam.look_at(look)
	cam.fov = fov
	cam.make_current()
