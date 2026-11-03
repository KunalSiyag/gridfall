extends SceneTree
## The room a carjack's pull-out has beside the door (carjack.gd _drop and _room, the carjack_throw
## flag with hit_feel): a car beside the door shortens the drop to the room there is, down to
## MIN_DROP, so the driver comes down in the gap and not through the next car or in its path; a car
## ahead of or behind in the same lane does not, whatever the distance or the offset (it once did,
## from 0.02 m off the axis), stopped or moving; and one beside the door counts from as far up or
## down the road as the door's own reach (half its length and SPAN_M), no further. The flags are
## eject's (fp_carjack_test: the plain slide with either off). The cars are bare vehicles in a stub
## of the traffic feature.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
## The car stands at the origin heading +Z, its driver's side +X: half its width, where the seat is
## along it.
const HALF_W := 0.9 * WS.M
const SEAT_Z := -0.2 * WS.M

var fails: Array[String] = []
var ran: Array[String] = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_room()
	_check_room_lane()
	FeatureFlags.reload()
	K.check(fails, ran.size() == 2, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_ROOM_TEST", fails)


## What carjack.gd's _drop reads of the traffic feature: its vehicles.
class VehStub:
	extends RefCounted
	var cars: Array = []


class FeatureStub:
	extends RefCounted
	var vehicles := VehStub.new()


## A car beside the door shortens the drop to the room there is (down to MIN_DROP), so the
## driver comes down in the gap and not through it or in its path; with nothing in reach it is
## DROP_M.
func _check_room() -> void:
	var cj := CJ.new()
	var fs := FeatureStub.new()
	cj.f = fs
	var car := VH.Car.new()
	car.half_w = HALF_W
	car.length = 4.5 * WS.M
	var xf := Transform3D.IDENTITY
	var cars: Array = fs.vehicles.cars
	cars.append(car)
	var free := cj._drop(car, xf, 0.0)
	K.check(fails, is_equal_approx(free, CJ.DROP_M), "no car near: the whole DROP_M")
	var gap := func(g: float, z: float, yaw: float = 0.0) -> VH.Car:
		var o := VH.Car.new()
		o.half_w = HALF_W
		o.length = 4.5 * WS.M
		o.yaw = yaw
		var reach := 0.5 * o.length * absf(sin(yaw)) + HALF_W * absf(cos(yaw))
		o.pos = Vector3(HALF_W + g * WS.M + reach, 0.0, z * WS.M)
		return o
	var near: VH.Car = gap.call(1.5, 0.0)
	cars.append(near)
	var room := cj._drop(car, xf, 0.0)
	var want := 1.5 - CJ.OUT / WS.M - CJ.BODY_CLEAR
	K.check(
		fails,
		absf(room - want) < 1e-6,
		"a car 1.5 m off the door: the room less the clearance (%.2f of %.2f m)" % [room, want]
	)
	near.pos.x = HALF_W + 0.8 * WS.M + HALF_W
	var tight := cj._drop(car, xf, 0.0)
	K.check(
		fails,
		is_equal_approx(tight, CJ.MIN_DROP),
		"a car almost against it: no less than MIN_DROP (%.2f m)" % tight
	)
	near.dead = true
	K.check(fails, is_equal_approx(cj._drop(car, xf, 0.0), CJ.DROP_M), "a dead car is no obstacle")
	near.dead = false
	near.pos.x = -near.pos.x
	K.check(
		fails, is_equal_approx(cj._drop(car, xf, 0.0), CJ.DROP_M), "nor is one off the other side"
	)
	near.pos = (gap.call(1.5, 8.0) as VH.Car).pos
	K.check(
		fails,
		is_equal_approx(cj._drop(car, xf, 0.0), CJ.DROP_M),
		"nor one up the road from a car that stands still"
	)
	car.v = 8.0 * WS.M
	var coming := cj._drop(car, xf, 0.0)
	K.check(
		fails,
		absf(coming - want) < 1e-6,
		"but a car moving on closes on the landing, the same 1.5 m (%.2f m)" % coming
	)
	car.v = 0.0
	cars.erase(near)
	var cross: VH.Car = gap.call(1.6, 0.0, 0.5 * PI)
	cars.append(cross)
	var side := cj._drop(car, xf, 0.0)
	var want_cross := 1.6 - CJ.OUT / WS.M - CJ.BODY_CLEAR
	K.check(
		fails,
		absf(side - want_cross) < 1e-6,
		"a car across the road counts by its length (%.2f of %.2f m)" % [side, want_cross]
	)
	cars.erase(cross)
	cars.append(near)
	near.pos = (gap.call(1.0, 0.0) as VH.Car).pos
	ran.append("room")


## A car ahead of or behind in the same lane is not beside the door, however it sits across the
## lane: it must not cut the drop (a lead car 0.02 m off the axis read as a neighbour and cut it
## to the least, so the driver landed sooner than planned). Stopped and moving (a moving
## car's reach is long: 1.5 s of its travel), either side of the axis, level or turned, from bumper
## to bumper to a dozen metres; and one genuinely beside the door still cuts it, at every place
## along the road within the door's reach, and not beyond it.
func _check_room_lane() -> void:
	var cj := CJ.new()
	var fs := FeatureStub.new()
	cj.f = fs
	var car := VH.Car.new()
	car.half_w = HALF_W
	car.length = 4.5 * WS.M
	var xf := Transform3D.IDENTITY
	fs.vehicles.cars.append(car)
	var cars: Array = fs.vehicles.cars
	var cut: Array[String] = []
	var tried := 0
	for v_ms: float in [0.0, 8.3, 14.0]:
		car.v = v_ms * WS.M
		for dir: float in [1.0, -1.0]:
			for gap_m: float in [0.3, 1.0, 2.5, 4.5, 7.0, 10.0, 14.0]:
				for off_m: float in [0.0, 0.02, 0.3, 0.8, 1.2, -0.3, -1.2]:
					for yaw: float in [0.0, 0.3, -0.3]:
						var o := VH.Car.new()
						o.half_w = HALF_W
						o.length = 4.5 * WS.M
						o.yaw = yaw
						o.pos = Vector3(off_m * WS.M, 0.0, dir * (car.length + gap_m * WS.M))
						cars.append(o)
						var got := cj._drop(car, xf, SEAT_Z)
						cars.erase(o)
						tried += 1
						if not is_equal_approx(got, CJ.DROP_M):
							cut.append(
								(
									"v %.1f %s %.1f m behind/ahead, %.2f m across, yaw %.1f: %.2f m"
									% [
										v_ms,
										"ahead" if dir > 0.0 else "behind",
										gap_m,
										off_m,
										yaw,
										got
									]
								)
							)
	K.check(
		fails,
		cut.is_empty(),
		(
			"%d cars ahead or behind in the lane: none cuts the drop (%d did: %s)"
			% [tried, cut.size(), str(cut.slice(0, 3))]
		)
	)
	# One beside the door, a flank-to-side gap of 1.5 m, along the road from far behind to ahead.
	var want := 1.5 - CJ.OUT / WS.M - CJ.BODY_CLEAR
	var miss: Array[String] = []
	for v_ms: float in [0.0, 8.3]:
		car.v = v_ms * WS.M
		for z_m: float in [-3.0, -1.5, 0.0, 1.5, 3.0]:
			var o := VH.Car.new()
			o.half_w = HALF_W
			o.length = 4.5 * WS.M
			o.pos = Vector3(HALF_W + 1.5 * WS.M + HALF_W, 0.0, z_m * WS.M + SEAT_Z)
			cars.append(o)
			var got := cj._drop(car, xf, SEAT_Z)
			cars.erase(o)
			if absf(got - want) > 1e-6:
				miss.append("v %.1f z %.1f: %.2f of %.2f m" % [v_ms, z_m, got, want])
	K.check(
		fails,
		miss.is_empty(),
		"a car beside the door, 1.5 m off it, anywhere along it: the drop is cut (%s)" % str(miss)
	)
	# A car turned across the road is as long along the road as it is wide, half its width either
	# side of its middle (the footprint as it lies in the car's frame, not half its length either
	# way): its flank is 1.5 m off the door, it is beside it up to a car's half width and the 1 m
	# span up the road, and 3 m up the road is out of reach; it once counted by half its length
	# (3.25 m).
	car.v = 0.0
	var turned: Array[String] = []
	var edge := HALF_W / WS.M + CJ.SPAN_M
	for z_m: float in [-3.0, -2.6, -1.5, 0.0, 1.5, 2.6, 3.0]:
		var o := VH.Car.new()
		o.half_w = HALF_W
		o.length = 4.5 * WS.M
		o.yaw = 0.5 * PI
		o.pos = Vector3(HALF_W + 1.5 * WS.M + 0.5 * o.length, 0.0, z_m * WS.M + SEAT_Z)
		cars.append(o)
		var got := cj._drop(car, xf, SEAT_Z)
		cars.erase(o)
		var beside := absf(z_m) < edge
		if absf(got - (want if beside else CJ.DROP_M)) > 1e-6:
			turned.append("z %.1f: %.2f m" % [z_m, got])
	K.check(
		fails,
		turned.is_empty(),
		"a car across the road counts by its width along it: %s" % str(turned)
	)
	car.v = 0.0
	var far := VH.Car.new()
	far.half_w = HALF_W
	far.length = 4.5 * WS.M
	far.pos = Vector3(HALF_W + 1.5 * WS.M + HALF_W, 0.0, 6.0 * WS.M + SEAT_Z)
	cars.append(far)
	K.check(
		fails,
		is_equal_approx(cj._drop(car, xf, SEAT_Z), CJ.DROP_M),
		"beside the next lane but 6 m up the road from a stopped car: out of its reach, no cut"
	)
	# The same lane car that also has a neighbour beside the door: the neighbour decides.
	var lead := VH.Car.new()
	lead.half_w = HALF_W
	lead.length = 4.5 * WS.M
	lead.pos = Vector3(0.0, 0.0, 6.0 * WS.M)
	cars.append(lead)
	far.pos = Vector3(HALF_W + 1.5 * WS.M + HALF_W, 0.0, SEAT_Z)
	K.check(
		fails,
		absf(cj._drop(car, xf, SEAT_Z) - want) < 1e-6,
		"with a lead car as well as a neighbour beside the door, the neighbour's room decides"
	)
	ran.append("room_lane")
