extends SceneTree
## The weather's per-frame write guards (the web per-frame budget). A settled sky repeats the same
## values for minutes, and a repeated write still dirties materials, buffers and transforms in the
## renderer, so a target that costs renderer work is written only when its value moved: the
## streets' wetness (CityView redoes a dry street on every call), the rain param (CityView.set_rain
## remembers what it wrote), the `wetness` global shader parameter and the emitters' spots. Each
## guard is pinned both ways, on a grown city on foot: a mark planted in the target behind the
## guard's back survives the frames that need no write, the write comes the moment the value
## moves, and a target made, reset or switched since (a road material made late, a world set up
## again, the street leaving first person) is written the next frame all the same.
## fp_write_guards_test checks the guarded targets against the unguarded writes frame by frame.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WEATHER := preload("res://scripts/fp/street/weather.gd")

var fails: Array[String] = []


## Counts the global `wetness` writes a weather makes (it writes through _write_global()).
class SpyWeather:
	extends "res://scripts/fp/street/weather.gd"
	var global_writes: int = 0

	func _write_global(_v: float) -> void:
		global_writes += 1


## A rain emitter that counts the transform writes it takes.
class EmitterProbe:
	extends GPUParticles3D
	var writes: int = 0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
			writes += 1


func _init() -> void:
	K.watchdog(self, "FP_WEATHER_GUARDS_TEST")
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "render": true, "hud": false})
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	var f := K.make_feature(ctx, "streetscape")
	K.check(fails, f != null, "the streetscape feature sets up")
	if f != null:
		_check_weather_guards(ctx, f)
		_check_exit_order(ctx, f)
	K.finish(self, "FP_WEATHER_GUARDS_TEST", fails)


## The weather's per-frame writes (the web per-frame budget). A settled sky repeats the same values
## for minutes, and a repeated write still dirties materials, buffers and transforms in the
## renderer, so each target that costs renderer work is written only when its value moved. Each is
## pinned both ways: a mark planted in the target behind the guard's back survives the frames that
## need no write, and the write comes the moment the value moves.
func _check_weather_guards(ctx: FpContext, f: FpFeature) -> void:
	var weather: Node = f.get("weather")
	var speed := ctx.sim.speed
	ctx.sim.speed = 1
	weather.set_process(false)
	_guard_wetness(ctx, f, weather)
	_guard_load(ctx, f)
	_guard_rain(ctx, f, weather)
	_guard_emitters(ctx, f, weather)
	_guard_global(ctx, f)
	_guard_rain_targets(ctx, f, weather)
	ctx.sim.speed = speed
	f.call("clear_forced_weather")
	weather.set_process(true)


## CityView's set_wetness drops a repeated wet value but redoes a dry street on every call (hundreds
## of material and shader writes), so weather asks it only while the streets are wet or still
## drying.
func _guard_wetness(ctx: FpContext, f: FpFeature, weather: Node) -> void:
	var view := ctx.view
	f.call("force_weather", "clear")
	weather.set("wet", 0.0)
	for _k in range(10):
		weather.call("step", 1.0)
	var mats: Dictionary = view.get("_wet_mats")
	var probe: BaseMaterial3D = null
	for m: BaseMaterial3D in mats.keys():
		if is_instance_valid(m):
			probe = m
			break
	K.check(
		fails,
		probe != null and view.wetness == 0.0,
		"wetness guard: a settled dry street to plant a mark in"
	)
	if probe == null:
		return
	var dry := float((mats[probe] as Array)[1])
	probe.roughness = 0.123
	for _k in range(5):
		weather.call("step", 1.0 / 60.0)
	K.check(
		fails,
		is_equal_approx(probe.roughness, 0.123),
		"wetness guard: a settled dry street rewrites no material (the planted mark stays)"
	)
	f.call("force_weather", "rain")
	weather.call("step", 1.0)
	K.check(
		fails,
		view.wetness > 0.0 and not is_equal_approx(probe.roughness, 0.123),
		"wetness guard: the rain starting wets the street again"
	)
	f.call("force_weather", "clear")
	weather.call("step", 1000.0)
	K.check(
		fails,
		view.wetness == 0.0 and is_equal_approx(probe.roughness, dry),
		"wetness guard: the street drying is dry to the last (the final dry call goes through)"
	)
	f.call("force_weather", "overcast")
	weather.call("step", 1.0)
	probe.roughness = 0.123
	for _k in range(5):
		weather.call("step", 1.0 / 60.0)
	K.check(
		fails,
		is_equal_approx(probe.roughness, 0.123),
		"wetness guard: a settled overcast street rewrites no material either"
	)


## A save loaded over settled dry streets wets them, and one loaded over wet streets dries them to
## the last: the dry skip asks the view what it holds, so a load (which sets the weather's wetness
## behind its back) reaches the materials either way.
func _guard_load(ctx: FpContext, f: FpFeature) -> void:
	var view := ctx.view
	f.call("force_weather", "clear")
	f.call("from_dict", {"wet": 0.0})
	K.check(fails, view.wetness == 0.0, "load guard: dry streets to load a save over")
	f.call("from_dict", {"wet": 0.6})
	K.check(
		fails,
		is_equal_approx(view.wetness, 0.6),
		"load guard: a wet save wets settled dry streets (%f)" % view.wetness
	)
	f.call("from_dict", {"wet": 0.0})
	K.check(
		fails,
		view.wetness == 0.0,
		"load guard: a dry save dries wet streets, to the last (%f)" % view.wetness
	)


## The rain param on the road and the water: CityView.set_rain remembers what it wrote (the
## weather asks it every frame), so a steady rain or a steady dry sky writes no param, and the rain
## starting or stopping is written at once.
func _guard_rain(ctx: FpContext, f: FpFeature, weather: Node) -> void:
	var road: ShaderMaterial = ctx.view.get("_road_fp_mat")
	var water: ShaderMaterial = ctx.view.get("_water_mat")
	K.check(fails, road != null and water != null, "rain guard: the road and water materials")
	if road == null or water == null:
		return
	var targets: Array[ShaderMaterial] = [road, water]
	f.call("force_weather", "rain")
	weather.call("step", 0.1)
	K.check(
		fails, _rains(targets, 1.0), "rain guard: the rain starting reaches the road and the water"
	)
	_plant_rain(targets, 0.25)
	for _k in range(5):
		weather.call("step", 0.1)
	K.check(
		fails,
		_rains(targets, 0.25),
		"rain guard: a steady rain writes no param (the planted marks stay)"
	)
	f.call("force_weather", "clear")
	weather.call("step", 0.1)
	K.check(fails, _rains(targets, 0.0), "rain guard: the rain stopping is written at once")
	_plant_rain(targets, 0.25)
	for _k in range(5):
		weather.call("step", 0.1)
	K.check(
		fails,
		_rains(targets, 0.25),
		"rain guard: a steady dry sky writes no param (the planted marks stay)"
	)
	f.call("force_weather", "rain")
	weather.call("step", 0.1)
	K.check(fails, _rains(targets, 1.0), "rain guard: the rain starting again is written at once")


## Whether every material's rain param is v (an unset param is not).
func _rains(mats: Array[ShaderMaterial], v: float) -> bool:
	for m: ShaderMaterial in mats:
		if m == null or m.get_shader_parameter("rain") != v:
			return false
	return true


## A mark in every material's rain param, behind CityView's back.
func _plant_rain(mats: Array[ShaderMaterial], v: float) -> void:
	for m: ShaderMaterial in mats:
		m.set_shader_parameter("rain", v)


## The materials the rain goes to are made, reset or switched without the weather being told (the
## feature is not sent world_rebuilt here, and the weather does not rely on it): the street leaving
## first person (off foot there is no rain), a road material made late (the first road dressed on
## foot) and a world set up again (a new water material). The next frame tells them all the same.
func _guard_rain_targets(ctx: FpContext, f: FpFeature, weather: Node) -> void:
	var view := ctx.view
	f.call("force_weather", "rain")
	weather.call("step", 0.1)
	K.check(
		fails, _rains(_rain_mats(view), 1.0), "rain targets: a steady rain on foot to switch under"
	)
	view.set_fp_mode(false)
	weather.call("step", 0.1)
	K.check(
		fails,
		_rains(_rain_mats(view), 0.0),
		"rain targets: the street off foot is told no rain the next frame"
	)
	view.set_fp_mode(true)
	view.call("flush_rebuild_queue")
	weather.call("step", 0.1)
	K.check(
		fails, _rains(_rain_mats(view), 1.0), "rain targets: back on foot the rain is told again"
	)
	view.set("_road_fp_mat", null)
	(view.get("_road_fp_variants") as Dictionary).clear()
	var late: ShaderMaterial = view.road_fp_material_for(1)
	K.check(fails, late != null, "rain targets: a road material made mid-rain")
	if late == null:
		return
	weather.call("step", 0.1)
	var late_mats: Array[ShaderMaterial] = [view.get("_road_fp_mat") as ShaderMaterial, late]
	K.check(
		fails,
		_rains(late_mats, 1.0),
		"rain targets: a road material made late is told the rain the next frame"
	)
	var variant: ShaderMaterial = view.road_fp_material_for(4)
	K.check(
		fails,
		variant != null and variant != late and variant.get_shader_parameter("rain") == 1.0,
		"rain targets: a road variant made mid-rain holds the rain at once (a copy of the base)"
	)
	var water_was: ShaderMaterial = view.get("_water_mat")
	view.setup(ctx.sim, view.camera)
	var water: ShaderMaterial = view.get("_water_mat")
	K.check(
		fails,
		water != null and water != water_was and water.get_shader_parameter("rain") == null,
		"rain targets: a world set up again has a new water material, told nothing yet"
	)
	weather.call("step", 0.1)
	K.check(
		fails,
		_rains(_rain_mats(view), 1.0),
		"rain targets: a world set up again is told the rain the next frame"
	)


## The water and road materials as CityView holds them now (the road's variants too).
func _rain_mats(view: CityView) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	out.append(view.get("_water_mat") as ShaderMaterial)
	out.append(view.get("_road_fp_mat") as ShaderMaterial)
	for sm: ShaderMaterial in (view.get("_road_fp_variants") as Dictionary).values():
		out.append(sm)
	return out


## The rain emitter follows the camera and the splash emitter the player's feet: a write only when
## the spot moved. The guard reads the emitter's own position, so one moved behind its back is put
## back as well.
func _guard_emitters(ctx: FpContext, f: FpFeature, weather: Node) -> void:
	var rain := weather.get("rain") as GPUParticles3D
	var splash := weather.get("splash") as GPUParticles3D
	var cam := get_root().get_camera_3d()
	K.check(
		fails,
		rain != null and splash != null and cam != null,
		"emitter guard: the emitters and a camera to follow"
	)
	if cam == null:
		return
	rain.set_script(EmitterProbe)
	splash.set_script(EmitterProbe)
	rain.set_notify_local_transform(true)
	splash.set_notify_local_transform(true)
	var rain_probe := rain as EmitterProbe
	var splash_probe := splash as EmitterProbe
	f.call("force_rain_for_photo")
	weather.call("step", 0.1)
	rain_probe.writes = 0
	splash_probe.writes = 0
	for _k in range(5):
		weather.call("step", 0.1)
	K.check(
		fails,
		splash.emitting and rain_probe.writes == 0 and splash_probe.writes == 0,
		(
			"emitter guard: a still camera and player take no emitter write (%d, %d)"
			% [rain_probe.writes, splash_probe.writes]
		)
	)
	var cam_at := cam.global_position
	var feet := ctx.player.position
	cam.global_position += Vector3(1.0, 0.0, 0.0)
	ctx.player.position += Vector3(0.0, 0.0, 1.0)
	weather.call("step", 0.1)
	K.check(
		fails,
		_follows(ctx, rain, splash, cam) and rain_probe.writes == 1 and splash_probe.writes == 1,
		(
			"emitter guard: a moved camera and player take the emitters along (%d, %d)"
			% [rain_probe.writes, splash_probe.writes]
		)
	)
	# only the height moved (a jump, stairs, a crouch): the emitters follow in y alone
	cam.global_position += Vector3(0.0, 0.8, 0.0)
	ctx.player.position += Vector3(0.0, 0.5, 0.0)
	rain_probe.writes = 0
	splash_probe.writes = 0
	weather.call("step", 0.1)
	K.check(
		fails,
		_follows(ctx, rain, splash, cam) and rain_probe.writes == 1 and splash_probe.writes == 1,
		(
			"emitter guard: a camera and a player that only changed height take them along (%d, %d)"
			% [rain_probe.writes, splash_probe.writes]
		)
	)
	rain.global_position += Vector3(5.0, 0.0, 0.0)
	rain_probe.writes = 0
	weather.call("step", 0.1)
	K.check(
		fails,
		rain_probe.writes == 1 and _follows(ctx, rain, splash, cam),
		"emitter guard: an emitter moved behind its back is put back"
	)
	splash.global_position += Vector3(0.0, 3.0, 0.0)
	splash_probe.writes = 0
	weather.call("step", 0.1)
	K.check(
		fails,
		splash_probe.writes == 1 and _follows(ctx, rain, splash, cam),
		"emitter guard: an emitter raised behind its back is put back"
	)
	cam.global_position = cam_at
	ctx.player.position = feet
	for e: GPUParticles3D in [rain, splash]:
		e.set_notify_local_transform(false)
		e.set_script(null)


## Whether the rain emitter is over the camera and the splash emitter at the player's feet.
func _follows(ctx: FpContext, rain: Node3D, splash: Node3D, cam: Camera3D) -> bool:
	var over_cam := rain.global_position.is_equal_approx(cam.global_position + Vector3(0, 0.35, 0))
	var at_feet := splash.global_position.is_equal_approx(
		ctx.player_position() + Vector3(0, 0.02 * WS.M, 0)
	)
	return over_cam and at_feet


## The `wetness` global shader parameter is written when the streets' wetness moved (and again
## after a setup()); a spy counts the writes.
func _guard_global(ctx: FpContext, f: FpFeature) -> void:
	var spy := SpyWeather.new()
	spy.name = "SpyWeather"
	spy.push_global = true
	f.add_child(spy)
	spy.set_process(false)
	spy.setup(ctx, "medium")
	var base := spy.global_writes
	K.check(fails, base == 1, "global guard: a set up weather writes the global once (%d)" % base)
	spy.force("clear")
	for _k in range(10):
		spy.step(1.0)
	K.check(
		fails,
		spy.global_writes == base,
		"global guard: a settled dry sky writes it no more (%d)" % spy.global_writes
	)
	spy.force("rain")
	for _k in range(3):
		spy.step(1.0)
	K.check(
		fails,
		spy.global_writes == base + 3,
		"global guard: streets getting wetter write it every time (%d)" % spy.global_writes
	)
	spy.force_soaked()
	var soaked := spy.global_writes
	for _k in range(5):
		spy.step(1.0)
	K.check(
		fails,
		soaked == base + 4 and spy.global_writes == soaked,
		"global guard: soaked streets write it once (%d, then %d)" % [soaked, spy.global_writes]
	)
	spy.setup(ctx, "medium")
	K.check(
		fails,
		spy.global_writes == soaked + 1,
		"global guard: setup() forgets what was told and writes it (%d)" % spy.global_writes
	)
	spy.step(1.0)
	K.check(
		fails,
		spy.global_writes == soaked + 1,
		"global guard: and then it is settled again (%d)" % spy.global_writes
	)
	spy.free()


## FpMode's exit: the features tear down (the weather node lives on until the frame ends), then
## the view leaves first person, and the weather's last frame still runs: no rain off foot.
func _check_exit_order(ctx: FpContext, f: FpFeature) -> void:
	var view := ctx.view
	var weather: Node = f.get("weather")
	f.call("force_weather", "rain")
	weather.call("step", 0.1)
	K.check(
		fails,
		_rains(_rain_mats(view), 1.0),
		"exit: a steady rain on foot before the street is torn down"
	)
	f.teardown()
	view.set_fp_mode(false)
	weather.call("step", 1.0 / 60.0)
	K.check(
		fails,
		_rains(_rain_mats(view), 0.0),
		"exit: the weather's last frame tells the street off foot no rain"
	)
