extends SceneTree
## The per-frame write guards of the weather and the animals (the web per-frame budget) against
## the writes they stand for: a repeated write still dirties materials, buffers and transforms in
## the renderer, so the weather and the animals write a target only when its value moved. For
## every frame of a scripted run, on a grown city on foot, the test snapshots what the renderer
## holds, makes the writes the code made before the guards (every hook, every rain param, every
## body root, the instance count, the leads' mesh, all of it, every frame) and asserts the snapshot
## did not change: no guard ever left a target stale. The run goes through clear and overcast
## skies, rain wetting the streets, soaked and drying, a smog incident, the quality presets, two
## dogs, cats, pigeons and squirrels standing about, an owner walking a dog on its lead, stopping
## and walking on, and the hero walking about. It ends with the targets made, reset or switched
## behind the weather's back: the street leaving first person and coming back, a road material
## made late, a world set up again (a new water material), a save loaded over wet streets and the
## street torn down the way FpMode's exit does it (the weather's last frame included). The area
## tests (fp_weather_guards_test, fp_streetscape_test, fp_animals_test, fp_cats_test,
## fp_squirrels_test, fp_pigeons_test) pin each guard both ways.

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LP := preload("res://scripts/fp/street/light_profile.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const LIFE := preload("res://scripts/fp/animals/cat_life.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var streetscape: FpFeature
var traffic: FpFeature
var animals: FpFeature
var weather: Node
var cam: Camera3D
## Frames checked, those whose reference writes changed something, and the first such (what).
var frames: int = 0
var drift: int = 0
var first_drift: String = ""
## What the run saw, so a pass cannot be an empty one.
var saw := {
	"dry_frames": 0,
	"wet_max": 0.0,
	"dogs": 0,
	"cats": 0,
	"leads": 0,
	"squirrels": 0,
	"smog": 0,
	"climbing": 0,
	"no_squirrels": 0,
	"rain_on": 0,
	"off_foot": 0,
}


func _init() -> void:
	K.watchdog(self, "FP_WRITE_GUARDS_TEST")
	await process_frame
	ctx = K.make_ctx(
		get_root(),
		{"view": true, "grow": true, "render": true, "hud": false, "camera_mode": "third"}
	)
	ctx.player.set_process(false)
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	streetscape = K.make_feature(ctx, "streetscape")
	traffic = K.make_feature(ctx, "traffic")
	animals = K.make_feature(ctx, "animals")
	cam = get_root().get_camera_3d()
	if streetscape == null or traffic == null or animals == null or cam == null:
		K.check(fails, false, "fixture: streetscape, traffic and animals registered, a camera")
		K.finish(self, "FP_WRITE_GUARDS_TEST", fails)
		return
	FRESH.wire(ctx, traffic, animals, Callable())
	FRESH.quiet(ctx, traffic)
	ctx.sim.speed = 1
	(animals.get("bodies") as Object).set("blocking", true)
	((animals.get("cats") as Object).get("bodies") as Object).set("blocking", true)
	weather = streetscape.get("weather")
	weather.set_process(false)
	_run_weather()
	_run_animals()
	_run_lifecycle()
	K.check(
		fails,
		drift == 0,
		(
			"every guarded write equals the unguarded one in %d frames (%d drifted, first: %s)"
			% [frames, drift, first_drift]
		)
	)
	K.check(
		fails,
		int(saw["dry_frames"]) > 100 and float(saw["wet_max"]) >= 0.99 and int(saw["smog"]) > 0,
		"the run covered dry and soaked streets and a smog incident (%s)" % str(saw)
	)
	K.check(
		fails,
		int(saw["dogs"]) > 0 and int(saw["cats"]) > 0 and int(saw["leads"]) > 0,
		"the run covered dogs, cats and a lead (%s)" % str(saw)
	)
	K.check(
		fails,
		int(saw["climbing"]) > 0 and int(saw["squirrels"]) > 0 and int(saw["no_squirrels"]) > 0,
		"the run covered a cat up a tree and squirrels coming and going (%s)" % str(saw)
	)
	K.check(
		fails,
		int(saw["rain_on"]) > 200 and int(saw["off_foot"]) > 20,
		"the run covered rain on the road and water, on foot and off it (%s)" % str(saw)
	)
	K.finish(self, "FP_WRITE_GUARDS_TEST", fails)


## Notes a drift (the reference writes changed the snapshot) of what at frame label.
func _compare(what: String, before: Array, after: Array, label: String) -> void:
	frames += 1
	if before == after:
		return
	drift += 1
	if first_drift.is_empty():
		var at := 0
		for k in range(mini(before.size(), after.size())):
			if before[k] != after[k]:
				at = k
				break
		first_drift = "%s %s #%d %s -> %s" % [what, label, at, str(before[at]), str(after[at])]


# ------------------------------------------------------------------ weather


## Everything the weather writes that the renderer holds: the sky hooks, the view's wetness and
## every material it darkens or wets, the rain params, the puddles, the reflections and the
## emitters.
func _weather_snapshot() -> Array:
	var sky := ctx.sky
	var view := ctx.view
	var snap: Array = [
		sky.weather_energy_mult,
		sky.weather_exposure_mult,
		sky.weather_shadow_mult,
		sky.weather_grey,
		sky.fog_begin_override,
		sky.weather_fog_tint,
		view.wetness,
		ctx.env.ssr_enabled,
	]
	var mats: Dictionary = view.get("_wet_mats")
	for m: BaseMaterial3D in mats.keys():
		if is_instance_valid(m):
			snap.append([m.albedo_color, m.roughness, m.metallic_specular])
	for key: String in [
		"_road_fp_mat", "_ground_fp_mat", "_lot_mat", "_lawn_mat", "_bank_mat", "_water_mat"
	]:
		var sm := view.get(key) as ShaderMaterial
		if sm != null:
			snap.append([key, sm.get_shader_parameter("wetness"), sm.get_shader_parameter("rain")])
	var variants: Dictionary = view.get("_road_fp_variants")
	for sm: ShaderMaterial in variants.values():
		snap.append([sm.get_shader_parameter("wetness"), sm.get_shader_parameter("rain")])
	var street: Object = view.get("_street")
	if street != null:
		for d in street.get("_puddles"):
			if is_instance_valid(d):
				snap.append([(d as Decal).modulate.a, (d as Decal).visible])
	var rain := weather.get("rain") as GPUParticles3D
	var splash := weather.get("splash") as GPUParticles3D
	snap.append([rain.emitting, rain.global_position, splash.emitting, splash.global_position])
	return snap


## The writes weather made every frame before the guards, as they were.
func _weather_reference() -> void:
	var look: Dictionary = weather.get("_look")
	var sky := ctx.sky
	var wet: float = weather.get("wet")
	var state := str(weather.get("state"))
	var smog: float = weather.get("_smog")
	sky.weather_energy_mult = float(look["energy"])
	sky.weather_exposure_mult = float(look["exposure"])
	sky.weather_shadow_mult = float(look["shadow"])
	sky.weather_grey = float(look["grey"])
	var fog := float(look["fog"])
	if smog > 0.01:
		fog = 5.0 if fog < 0.0 else minf(fog, 5.0)
	sky.fog_begin_override = fog
	sky.weather_fog_tint = Color(0.62, 0.55, 0.36, clampf(smog, 0.0, 0.85))
	ctx.view.set_wetness(wet)
	_rain_reference(state == "rain")
	LP.set_wet(ctx.env, str(weather.get("preset")), wet)
	var rain := weather.get("rain") as GPUParticles3D
	var splash := weather.get("splash") as GPUParticles3D
	rain.global_position = cam.global_position + Vector3(0, 0.35, 0)
	if splash.emitting:
		splash.global_position = ctx.player_position() + Vector3(0, 0.02 * WS.M, 0)


## The rain param on every target, written straight into it the way CityView.set_rain did on every
## call (so not through CityView's own memory of what it wrote): none off foot.
func _rain_reference(raining: bool) -> void:
	var on := 1.0 if raining and ctx.view.fp_mode else 0.0
	for key: String in ["_water_mat", "_road_fp_mat"]:
		var sm := ctx.view.get(key) as ShaderMaterial
		if sm != null:
			sm.set_shader_parameter("rain", on)
	for sm: ShaderMaterial in (ctx.view.get("_road_fp_variants") as Dictionary).values():
		sm.set_shader_parameter("rain", on)


## One weather frame of delta seconds, then the same snapshot-reference-snapshot check.
func _weather_frame(label: String, delta: float) -> void:
	cam.global_position = ctx.player_position() + Vector3(0.0, WS.EYE, 0.0)
	weather.call("step", delta)
	var before := _weather_snapshot()
	_weather_reference()
	_compare("weather", before, _weather_snapshot(), label)
	if ctx.view.wetness == 0.0 and float(weather.get("wet")) == 0.0:
		saw["dry_frames"] = int(saw["dry_frames"]) + 1
	saw["wet_max"] = maxf(float(saw["wet_max"]), float(weather.get("wet")))
	var water := ctx.view.get("_water_mat") as ShaderMaterial
	if water != null and water.get_shader_parameter("rain") == 1.0:
		saw["rain_on"] = int(saw["rain_on"]) + 1
	if not ctx.view.fp_mode:
		saw["off_foot"] = int(saw["off_foot"]) + 1


func _weather_phase(label: String, n: int, delta: float) -> void:
	for _k in range(n):
		_weather_frame(label, delta)


func _run_weather() -> void:
	var walk := Vector3(0.0, 0.0, 1.0) * WS.M * 1.4 * DT
	streetscape.call("force_weather", "clear")
	_weather_phase("clear", 90, DT)
	streetscape.call("force_weather", "rain")
	_weather_phase("rain wetting", 90, 2.0)
	_weather_phase("rain", 60, DT)
	for _k in range(60):
		ctx.player.position += walk
		_weather_frame("rain, hero walking", DT)
	streetscape.call("force_rain_for_photo")
	_weather_phase("rain soaked", 60, DT)
	streetscape.call("force_weather", "overcast")
	_weather_phase("overcast drying", 90, 5.0)
	_weather_phase("overcast", 60, DT)
	streetscape.call("force_weather", "clear")
	_weather_phase("clear drying", 90, 5.0)
	_weather_phase("clear", 90, DT)
	streetscape.call("force_weather", "rain")
	_weather_phase("rain again", 40, 2.0)
	var at := ctx.player_position()
	var ev := {"type": "smog", "x": roundi(at.x), "y": roundi(at.z), "radius": 3}
	ctx.sim.events.append(ev)
	streetscape.call("force_weather", "clear")
	for _k in range(60):
		_weather_frame("smog", 0.5)
		saw["smog"] = int(saw["smog"]) + (1 if float(weather.get("_smog")) > 0.01 else 0)
	ctx.sim.events.erase(ev)
	_weather_phase("smog gone", 60, 0.5)
	for preset: String in ["high", "low", "medium"]:
		weather.call("set_rain_amount", preset)
		_weather_phase("preset " + preset, 30, DT)
	streetscape.call("clear_forced_weather")
	streetscape.call("force_weather", "clear")
	weather.call("step", 1000.0)


# ------------------------------------------------------------------ lifecycle


## The targets made, reset or switched behind the weather's back (the feature is not sent
## world_rebuilt: the weather must not need it), then FpMode's exit. Weather frames only.
func _run_lifecycle() -> void:
	var view := ctx.view
	streetscape.call("force_weather", "rain")
	_weather_phase("lifecycle: rain", 30, 2.0)
	# the street leaves first person (no rain off foot) and comes back
	view.set_fp_mode(false)
	_weather_phase("off foot", 20, DT)
	view.set_fp_mode(true)
	view.call("flush_rebuild_queue")
	_weather_phase("back on foot", 20, DT)
	# a road material made late: the first road dressed on foot
	view.set("_road_fp_mat", null)
	(view.get("_road_fp_variants") as Dictionary).clear()
	view.road_fp_material_for(2)
	_weather_phase("a road material made late", 20, DT)
	# a world set up again: a new water material
	view.setup(ctx.sim, view.camera)
	_weather_phase("a world set up again", 20, DT)
	# a save with dry streets loaded over soaked ones
	streetscape.call("force_rain_for_photo")
	_weather_phase("soaked", 10, DT)
	streetscape.call("force_weather", "clear")
	streetscape.call("from_dict", {"wet": 0.0})
	_weather_phase("a dry save loaded over wet streets", 20, DT)
	# FpMode's exit: the features tear down, the view leaves first person, and the weather node
	# (it lives until the frame ends) has one more frame
	streetscape.call("force_weather", "rain")
	_weather_phase("rain before the exit", 30, 2.0)
	streetscape.call("teardown")
	view.set_fp_mode(false)
	_weather_phase("the weather's last frame after the exit", 1, DT)


# ------------------------------------------------------------------ animals


## What the animals write that the renderer holds: the body roots, the squirrels' instance count
## and the leads' mesh.
func _animal_snapshot() -> Array:
	var snap: Array = []
	for d in (animals.get("pack") as Object).get("dogs"):
		snap.append([d.body.root.position, d.body.root.rotation])
	var cat_life: Object = (animals.get("cats") as Object).get("life")
	for c in cat_life.get("cats"):
		snap.append([c.body.root.position, c.body.root.rotation])
	var node := (animals.get("squirrels") as Object).get("_node") as MultiMeshInstance3D
	snap.append(node.multimesh.visible_instance_count if node != null else -1)
	var leads := animals.get("leads") as MeshInstance3D
	snap.append([leads.get("count"), leads.mesh.get_surface_count(), leads.mesh.get_aabb()])
	return snap


## The writes the animals made every frame before the guards, as they were.
func _animal_reference() -> void:
	for d in (animals.get("pack") as Object).get("dogs"):
		d.body.root.position = d.pos
		d.body.root.rotation = Vector3(0.0, d.yaw, 0.0)
	var cat_life: Object = (animals.get("cats") as Object).get("life")
	for c in cat_life.get("cats"):
		var pos: Vector3 = c.pos
		var rot := Vector3(0.0, c.yaw, 0.0)
		if c.act in ["climb", "hold", "down"]:
			pos += Vector3.UP * c.climb_y
			rot = Vector3(LIFE.CLIMB_PITCH, c.yaw, 0.0)
		c.body.root.position = pos
		c.body.root.rotation = rot
	var sq := animals.get("squirrels") as Object
	var node := sq.get("_node") as MultiMeshInstance3D
	if node != null:
		var life: Object = sq.get("life")
		node.multimesh.visible_instance_count = mini(
			(life.get("squirrels") as Array).size(), node.multimesh.instance_count
		)
	var near: Array = []
	var at: Vector3 = animals.call("_camera_pos")
	for l: Array in (animals.get("pack") as Object).call("leads"):
		if (l[1] as Vector3).distance_to(at) < AF.LEAD_VIS:
			near.append(l)
	(animals.get("leads") as Object).call("draw", near, at)


func _animal_frame(label: String) -> void:
	cam.global_position = ctx.player_position() + Vector3(0.0, WS.EYE, 0.0)
	traffic.call("step", DT)
	animals.call("tick", DT)
	var before := _animal_snapshot()
	_animal_reference()
	_compare("animals", before, _animal_snapshot(), label)
	var pack: Object = animals.get("pack")
	saw["dogs"] = maxi(int(saw["dogs"]), (pack.get("dogs") as Array).size())
	var cat_life: Object = (animals.get("cats") as Object).get("life")
	saw["cats"] = maxi(int(saw["cats"]), (cat_life.get("cats") as Array).size())
	for c in cat_life.get("cats"):
		saw["climbing"] = int(saw["climbing"]) + (1 if c.act in ["climb", "hold", "down"] else 0)
	var sq_life: Object = (animals.get("squirrels") as Object).get("life")
	var sq_n := (sq_life.get("squirrels") as Array).size()
	saw["squirrels"] = maxi(int(saw["squirrels"]), sq_n)
	if int(saw["squirrels"]) > 0 and sq_n == 0:
		saw["no_squirrels"] = int(saw["no_squirrels"]) + 1
	saw["leads"] = maxi(int(saw["leads"]), int((animals.get("leads") as Object).get("count")))


func _animal_phase(label: String, n: int) -> void:
	for _k in range(n):
		_animal_frame(label)


func _run_animals() -> void:
	streetscape.call("force_weather", "clear")
	ctx.sky.fixed_hour = 12.0
	ctx.sky.hour = 12.0
	ctx.sky.night = 0.0
	# the photo shots' animals stand still on game time with the sim paused: a settled street
	animals.call("on_world_rebuilt")
	var shots: Array = animals.call("photo_shots")
	for s: Dictionary in shots:
		ctx.player.teleport(s["pos"], float(s["yaw"]))
		animals.call(str(s["prepare"]))
	if not shots.is_empty():
		ctx.player.teleport(shots[0]["pos"], float(shots[0]["yaw"]))
	_animal_phase("settled animals", 240)
	var yaw := deg_to_rad(float(shots[0]["yaw"])) if not shots.is_empty() else 0.0
	var stroll := Vector3(-sin(yaw), 0.0, -cos(yaw)) * WS.M * 1.4 * DT * 0.3
	for _k in range(120):
		ctx.player.position += stroll
		_animal_frame("hero strolling by")
	# a cat up its refuge tree clings there, then comes down
	var cat_life: Object = (animals.get("cats") as Object).get("life")
	var cats_now: Array = cat_life.get("cats")
	if not cats_now.is_empty():
		var c = cats_now[0]
		c.act = "hold"
		c.climb_y = 1.0 * WS.M
		c.calm_t = 0.0
		c.tree = [c.pos.x, c.pos.z, 0.1]
	_animal_phase("a cat up its tree", 360)
	for s: Dictionary in shots:
		animals.call(str(s["restore"]))
	_animal_phase("photo animals gone", 30)
	# the rain sends the animals in (the squirrels all go), and they come out again
	streetscape.call("force_weather", "rain")
	_animal_phase("rain", 120)
	streetscape.call("force_weather", "clear")
	_animal_phase("clear again", 150)
	_run_owner()


## An owner walking a dog on its lead, stopping (the dog is let off) and walking on.
func _run_owner() -> void:
	var walk: Dictionary = K.sidewalk(ctx, 0.6)
	if walk.is_empty():
		K.check(fails, false, "fixture: a straight sidewalk for the owner")
		return
	ctx.player.teleport(walk["pos"], float(walk["yaw"]))
	var r := FRESH.dog_owner(ctx, 0, "park")
	var wk: Object = traffic.get("walkers")
	var w = wk.make("resident")
	w.extra = 0
	w.resident_id = str(r["id"])
	var run: Vector3 = walk["run"]
	wk.stand(w, (walk["pos"] as Vector3) + run * 0.05, atan2(run.x, run.z))
	_animal_phase("a dog comes out", 60)
	var on := func(label: String, n: int) -> void:
		for _k in range(n):
			var p: Vector3 = w.pos + run * 1.4 * WS.M * DT
			var y: float = ctx.collision.walk_height(p)
			p.y = y if not is_nan(y) else w.pos.y
			w.pos = p
			w.yaw = atan2(run.x, run.z)
			_animal_frame(label)
	on.call("owner walking the dog", 240)
	_animal_phase("owner stopped", 360)
	on.call("owner walks on", 180)
	wk.remove(w)
	_animal_phase("owner gone", 240)
