extends SceneTree
## Deterministic, windowed proof of round 3's night driving (the night_driving flag): the hero's
## own guaranteed lamp lighting the road ahead of the car they wait in (the one headlamp that
## cannot lose the shared pool's eight slots), the bicycle's smaller lamp at its handlebar, each
## once by day for the contrast, and the whole render stack up under GL with the new light. Run
## windowed with GRIDFALL_OFFLINE=1, GRIDFALL_NEW_CITY=1 and an isolated XDG_DATA_HOME; images go
## to --output=<absolute directory>. The bench (context, features, stepping, shots, the staged
## road, the pull-up and the emptied road) is tools/proof_kit.gd; the staged machines, the held
## sky and the framings are this proof's own.

const KIT := preload("res://tools/proof_kit.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const RD := preload("res://scripts/fp/traffic/render.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
## The held clock: well past dusk (the sky's night at 1) and noon (at 0).
const NIGHT_HOUR := 23.0
const DAY_HOUR := 12.0

var kit: KIT
## The machine the hero waits in: the framings are set per shot, not per frame, because nothing
## moves between the settling and the shot.
var _car: VH.Car


func _init() -> void:
	await process_frame
	kit = KIT.new()
	kit.tag = "NIGHT_PROOF"
	kit.bench(self, "/tmp/gf-r3-night-proof")
	kit.traffic.set("ambient_enabled", false)
	if not kit.road():
		kit.finish()
		return
	await _car_beams()
	if not kit.failed:
		await _bike_lamp()
	kit.finish()


## The hero's own beam over the road ahead of the car they wait in (the night_driving flag): the
## sky held dark, the lamp placed and lit through the glow, the pool framed from the quarter and
## from behind; then the same wheel by day, where it is off.
func _car_beams() -> void:
	var m: int = kit.traffic.call("car_model_for", "night proof")
	if m < 0:
		kit.fail("a resident's car model is loaded")
		return
	kit.clear_cars()
	kit.quiet_walkers()
	var c := _vh().make("car", "ambient", kit.traffic.call("dims", m))
	c.model = m
	_vh().place(c, kit.lanes[0], 0.35)
	c.v = 0.0
	_sky(NIGHT_HOUR)
	kit.beside(c)
	if not bool(kit.drive.call("enter")):
		kit.fail("the hero gets into the car")
		return
	_car = kit.car()
	var node: Node3D = await kit.load_model()
	if node == null:
		kit.fail("the car's full model is loaded")
		return
	await kit.settle(50)
	_lamp_check(true, false)
	_frame("car_night")
	await kit.shot("car_night")
	_frame("car_night_rear")
	await kit.shot("car_night_rear")
	_sky(DAY_HOUR)
	await kit.settle(50)
	_lamp_check(false, false)
	_frame("car_day")
	await kit.shot("car_day")
	await kit.stop_and_leave()
	kit.clear_cars()


## The bicycle's own small lamp (the night_driving flag): the hero back on it under the same
## dark sky, the smaller dimmer pool framed from the quarter, then by day.
func _bike_lamp() -> void:
	var m: int = kit.traffic.call("bike_model")
	if m < 0:
		kit.fail("the bicycle model is loaded")
		return
	kit.quiet_walkers()
	var c := _vh().make("bike", "ambient", kit.traffic.call("dims", m))
	c.model = m
	_vh().place(c, kit.lanes[0], 0.35)
	c.v = 0.0
	_sky(NIGHT_HOUR)
	kit.beside(c)
	if not bool(kit.drive.call("enter")):
		kit.fail("the hero gets on the bicycle")
		return
	_car = kit.car()
	var node: Node3D = await kit.load_model()
	if node == null:
		kit.fail("the bicycle's full model is loaded")
		return
	await kit.settle(50)
	_lamp_check(true, true)
	_frame("bike_night")
	await kit.shot("bike_night")
	_sky(DAY_HOUR)
	await kit.settle(50)
	_lamp_check(false, true)
	_frame("bike_day")
	await kit.shot("bike_day")
	await kit.stop_and_leave()
	kit.clear_cars()


## The hero's lamp state against the sky — placed and visible after dark, off by day — and, when
## on, the right one of the two: the full beam in the car, the small dim lamp on the bicycle.
func _lamp_check(on: bool, bike: bool) -> void:
	var rd: RD = kit.traffic.get("render")
	var lamp := rd.hero_lamp
	var lit: bool = bool(rd.hero_beam_on) and lamp != null and lamp.visible
	if lit != on:
		kit.fail("the hero's lamp is %s (night %.2f)" % ["on" if on else "off", kit.ctx.sky.night])
	if on:
		var angle := RD.HERO_BIKE_ANGLE if bike else RD.BEAM_ANGLE
		if lamp == null or absf(lamp.spot_angle - angle) > 0.01:
			kit.fail("the %s's lamp is the right one" % ("bicycle" if bike else "car"))


## Puts the shot camera on one of the proof's framings of the machine the hero waits in: the
## front quarter (the nose and the pool before it), behind it looking down the lit road, or
## close before the bicycle.
func _frame(aim: String) -> void:
	var cam: Camera3D = kit.ctx.player.camera
	if cam == null:
		return
	var c := _car
	var f := OBB.heading(c.yaw)
	var side := Vector2(f.y, -f.x)
	var p := c.pos + Vector3(c.vis_off.x, 0.0, c.vis_off.z)
	var at := p
	var look := p
	var fov := 42.0
	match aim:
		"car_night", "car_day":
			at = (
				p
				+ Vector3(f.x, 0.0, f.y) * (c.length * 1.8)
				+ Vector3(side.x, 0.0, side.y) * (c.length * 1.1)
				+ Vector3.UP * 2.0 * WS.M
			)
			look = p + Vector3(f.x, 0.0, f.y) * (c.length * 0.9) + Vector3.UP * 0.2 * WS.M
			fov = 50.0
		"car_night_rear":
			at = (
				p
				- Vector3(f.x, 0.0, f.y) * (c.length * 1.4)
				+ Vector3(side.x, 0.0, side.y) * (c.length * 0.3)
				+ Vector3.UP * 2.4 * WS.M
			)
			look = p + Vector3(f.x, 0.0, f.y) * (c.length + 26.0 * WS.M) + Vector3.UP * 0.4 * WS.M
			fov = 48.0
		"bike_night", "bike_day":
			at = (
				p
				+ Vector3(f.x, 0.0, f.y) * (c.length * 1.2)
				+ Vector3(side.x, 0.0, side.y) * 2.2 * WS.M
				+ Vector3.UP * 1.4 * WS.M
			)
			look = p + Vector3(f.x, 0.0, f.y) * (c.length + 10.0 * WS.M) + Vector3.UP * 0.2 * WS.M
			fov = 44.0
	cam.position = at
	cam.look_at(look)
	cam.fov = fov
	cam.make_current()


## Holds the sky at the given hour, blended fully at once: the bench pauses its clock, and night
## is derived from the hour on every apply, so the hour is what must be held.
func _sky(hour: float) -> void:
	kit.ctx.sky.fixed_hour = hour
	kit.ctx.sky.call("_process", 1.0)


func _vh() -> VH:
	return kit.traffic.get("vehicles")
