extends RefCounted
## Shared helpers for first-person tests (docs/fp/S0-foundation.md §17.2): a sim with residents,
## a scripted growth recipe with asserted fixtures, a headless CityView, and a complete FpContext
## wired without Main (stub FpMode, headless FpPlayer, FpHud, SkyDirector, optional render/audio).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")
## The scripted growth recipe used by "grow" (probe-verified on seed 7): the nine actions at
## residents_test.gd:29-37 plus an L-shaped road (corner at (4,12), tee at (10,12)).
const GROW_ACTIONS := [
	{"type": "build", "building": "coal_plant", "x": 9, "y": 9},
	{"type": "build", "building": "water_pump", "x": 9, "y": 7},
	{"type": "road", "x": 2, "y": 5, "x2": 9, "y2": 5},
	{"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 6, "h": 3},
	{"type": "zone", "zone": "C", "x": 2, "y": 3, "w": 6, "h": 2},
	{"type": "build", "building": "sewage_plant", "x": 9, "y": 3},
	{"type": "build", "building": "fire_station", "x": 1, "y": 9},
	{"type": "zone", "zone": "I", "x": 11, "y": 2, "w": 4, "h": 4},
	{"type": "road", "x": 11, "y": 6, "x2": 15, "y2": 6},
	{"type": "road", "x": 9, "y": 12, "x2": 4, "y2": 14},
]
const DEFAULT_OPTS := {
	"seed": 7, "minds": false, "grow": false, "ticks": 0, "view": false,
	"render": false, "player": true, "hud": true, "audio": false, "client": null,
	"camera_mode": "first",
}
const GROW_CAP_TICKS := 120


## CitySim(new_city(seed)) + Residents (+ ResidentMinds when minds = true) + a GmiClient (the
## injected client, else a new offline one with live_enabled = false), all under root. An injected
## client keeps the live_enabled and api_key it came with: GmiClient._ready (run by add_child) would
## otherwise force live off under GRIDFALL_OFFLINE=1 and load the real key into the fake.
## Returns {"sim", "people", "minds", "client"}.
static func make_sim(root: Node, seed: int = 7, minds: bool = false, client: GmiClient = null) -> Dictionary:
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	sim.name = "CitySim"
	root.add_child(sim)
	sim.new_city(seed)
	var c := client
	if c == null:
		c = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
		c.name = "GmiClient"
	if not c.is_inside_tree():
		var live := c.live_enabled
		var key := c.api_key
		root.add_child(c)
		if client != null:
			c.live_enabled = live
			c.api_key = key
	if client == null:
		c.live_enabled = false
	var people: Residents = (load("res://scripts/sim/residents.gd") as GDScript).new()
	people.name = "Residents"
	root.add_child(people)
	var m: ResidentMinds = null
	if minds:
		m = (load("res://scripts/ai/resident_minds.gd") as GDScript).new()
		m.name = "ResidentMinds"
		root.add_child(m)
	people.setup(sim)
	if m != null:
		m.setup(sim, people, c, null)
	return {"sim": sim, "people": people, "minds": m, "client": c}


## Applies GROW_ACTIONS through sim.apply_action(0, a), calls sim.start(), then step_tick()s until
## at least min_ticks ticks ran AND people has >= 5 residents AND >= 1 ZONE_C lot is at level >= 1,
## capped at 120 ticks. Returns the tick count.
static func grow(sim: CitySim, people: Residents, min_ticks: int = 40) -> int:
	for a: Dictionary in GROW_ACTIONS:
		sim.apply_action(0, a)
	sim.start()
	var n := 0
	while n < GROW_CAP_TICKS:
		if n >= min_ticks and people.people.size() >= 5 and _has_c_lot(sim):
			break
		sim.step_tick()
		n += 1
	return n


## Runs n synchronous ticks.
static func ticks(sim: CitySim, n: int) -> void:
	for _k in range(n):
		sim.step_tick()


## A CityView set up on sim with a throwaway Camera3D (needs the .godot import cache).
static func make_view(root: Node, sim: CitySim) -> CityView:
	var cam := Camera3D.new()
	cam.name = "KitViewCamera"
	root.add_child(cam)
	var view: CityView = (load("res://scripts/world/city_view.gd") as GDScript).new()
	view.name = "CityView"
	root.add_child(view)
	view.setup(sim, cam)
	return view


## An FpContext wired for unit tests without Main (S0 §17.2 field table).
## opts (defaults): {"seed": 7, "minds": false, "grow": false, "ticks": 0, "view": false,
##   "render": false, "player": true, "hud": true, "audio": false, "client": null,
##   "camera_mode": "first"}. camera_mode overrides FpMode's play default ("third", D13), so every
##   test runs in first person unless it passes "third".
## Call it after `await process_frame` in a SceneTree test's _init, so root is inside the tree.
static func make_ctx(root: Node, opts: Dictionary = {}) -> FpContext:
	if not root.is_inside_tree():
		push_warning("fp_kit.make_ctx: root is not inside the tree yet; await process_frame first")
	var o := DEFAULT_OPTS.duplicate()
	o.merge(opts, true)
	var kit := Node3D.new()
	kit.name = "FpKit"
	root.add_child(kit)
	var ctx := FpContext.new()
	ctx.settings = FpMode.DEFAULT_SETTINGS.duplicate(true)
	ctx.settings["camera_mode"] = str(o["camera_mode"])
	# 1. sim, residents, minds, client (an injected client is in place before anything else).
	var s := make_sim(kit, int(o["seed"]), bool(o["minds"]), o["client"])
	ctx.sim = s["sim"]
	ctx.residents = s["people"]
	ctx.minds = s["minds"]
	ctx.client = s["client"]
	# 2. growth, before the brain and the view exist. Always offline: with an injected client the
	# minds talk to an offline stand-in (same replay cache) meanwhile, so the recipe stays
	# probe-verified and the fake sees no call before the test starts.
	var stand_in: GmiClient = null
	if ctx.minds != null and o["client"] != null and (bool(o["grow"]) or int(o["ticks"]) > 0):
		stand_in = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
		stand_in.live_enabled = false
		stand_in.replay_cache = ctx.client.replay_cache
		ctx.minds.client = stand_in
	if bool(o["grow"]):
		grow(ctx.sim, ctx.residents, maxi(int(o["ticks"]), 40))
	elif int(o["ticks"]) > 0:
		ctx.sim.start()
		ticks(ctx.sim, int(o["ticks"]))
	if stand_in != null:
		ctx.minds.client = ctx.client
		stand_in.free()
	# 3. brain.
	var brain: CityBrain = (load("res://scripts/ai/city_brain.gd") as GDScript).new()
	brain.name = "CityBrain"
	kit.add_child(brain)
	brain.setup(ctx.sim, ctx.client)
	brain.minds = ctx.minds
	if ctx.minds != null:
		ctx.minds.brain = brain
		ctx.minds.plans_done.connect(brain.residents_spoke)
	ctx.brain = brain
	# 4. view.
	if bool(o["view"]):
		ctx.view = make_view(kit, ctx.sim)
	# 5. render: a private copy of the environment and the main.tscn Sun.
	if bool(o["render"]):
		var cam := Camera3D.new()
		cam.name = "KitRenderCamera"
		cam.environment = ResourceLoader.load("res://scenes/main-environment.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as Environment
		kit.add_child(cam)
		cam.make_current()
		ctx.env = cam.environment
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.transform = Transform3D(Basis(Vector3(-0.422618, 0, -0.906308), Vector3(-0.694272, 0.642788, 0.323744), Vector3(0.582563, 0.766044, -0.271654)), Vector3.ZERO)
		sun.light_color = Color(0.98, 0.95, 0.9, 1)
		sun.light_energy = 1.15
		sun.shadow_enabled = true
		sun.shadow_opacity = 0.85
		sun.shadow_blur = 1.2
		sun.directional_shadow_max_distance = 90.0
		kit.add_child(sun)
		ctx.sun = sun
	# 6. sky (always, so sky.clock_text() works).
	var sky := SkyDirector.new()
	sky.name = "SkyDirector"
	kit.add_child(sky)
	sky.setup(ctx.sim, ctx.env, ctx.sun, ctx.view)
	ctx.sky = sky
	# 7. bus, directory, collision, world root.
	var bus := GameBus.new()
	bus.name = "Bus"
	kit.add_child(bus)
	ctx.bus = bus
	var dir := CityDirectory.new()
	dir.setup(ctx.sim)
	ctx.directory = dir
	var col := CollisionWorld.new()
	col.name = "Collision"
	kit.add_child(col)
	col.setup(ctx)
	ctx.collision = col
	if ctx.view != null:
		col.rebuild_all()
		ctx.view.tile_built.connect(col.on_tile_built)
		ctx.view.tile_cleared.connect(col.on_tile_cleared)
	var world := Node3D.new()
	world.name = "World"
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	kit.add_child(world)
	ctx.world_root = world
	var features := Node3D.new()
	features.name = "Features"
	kit.add_child(features)
	# 8. a stub FpMode: never setup(), but time, pause, settings and spawn_point() work.
	var mode := FpMode.new()
	mode.name = "FpModeStub"
	kit.add_child(mode)
	mode.ctx = ctx
	mode.bus = bus
	mode.collision = col
	mode.directory = dir
	mode.time_scale = 1
	mode.paused = false
	ctx.mode = mode
	# 9. player, 10. hud, 11. audio.
	if bool(o["player"]):
		make_player(ctx)
	if bool(o["hud"]):
		var hud := FpHud.new()
		hud.name = "FpHud"
		kit.add_child(hud)
		ctx.hud = hud
		mode.hud = hud
		hud.setup(ctx)
	if bool(o["audio"]):
		var audio: GridFallAudioDirector = (load("res://scripts/audio_director.gd") as GDScript).new()
		audio.name = "AudioDirector"
		kit.add_child(audio)
		ctx.audio = audio
	return ctx


## A headless FpPlayer (input_enabled = false) under the kit root; sets ctx.player and
## ctx.mode.player, teleports to spawn_point(). make_ctx calls it when opts.player is true.
static func make_player(ctx: FpContext) -> FpPlayer:
	var p := FpPlayer.new()
	p.name = "Player"
	p.input_enabled = false
	ctx.world_root.get_parent().add_child(p)
	ctx.player = p
	if ctx.mode != null:
		ctx.mode.player = p
	p.setup(ctx)
	var sp: Dictionary = ctx.mode.spawn_point() if ctx.mode != null else {"pos": Vector3.ZERO, "yaw": 0.0}
	p.teleport(sp["pos"], float(sp["yaw"]))
	return p


## Instantiates a registered feature by id from fp_features.gd, adds it under the kit's
## "Features" Node3D (so it is inside the tree and its _process runs when the test yields frames),
## sets ctx.features[id], then runs setup(ctx) and on_world_rebuilt().
static func make_feature(ctx: FpContext, id: String) -> FpFeature:
	var path := ""
	for e: Dictionary in REGISTRY.FEATURES:
		if str(e["id"]) == id:
			path = str(e["path"])
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("fp_kit: no registered feature " + id)
		return null
	var f: FpFeature = (load(path) as GDScript).new()
	f.name = id
	ctx.world_root.get_parent().get_node("Features").add_child(f)
	ctx.features[id] = f
	f.setup(ctx)
	f.on_world_rebuilt()
	return f


## A sidewalk point on a straight road with a clear line `length` (u) ahead along the run, nothing
## within 1.5 player radii of it: {"pos" (the feet), "yaw" (deg, along the run), "run" (unit)}, or
## {} when the city has none.
static func sidewalk(ctx: FpContext, length: float) -> Dictionary:
	var sim := ctx.sim
	var col := ctx.collision
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		var run := RoadTopology.run_dir(m)
		var start := RoadTopology.sidewalk_point(sim, i, 1) - run * 0.3
		var ok := true
		for k in range(int(length / 0.02) + 4):
			var q := start + run * (0.02 * k)
			var g := col.walk_height(q)
			ok = ok and not is_nan(g) and absf(g - WS.SIDEWALK_TOP) < 1e-6
			ok = ok and not col.is_blocked(Vector3(q.x, g, q.z), WS.PLAYER_RADIUS * 1.5)
		if ok:
			start.y = col.walk_height(start)
			return {"pos": start, "yaw": rad_to_deg(atan2(-run.x, -run.z)), "run": run}
	return {}


## Prints "<TOKEN>: PASS" or "<TOKEN>: FAIL <fails>" and quits 0/1. fails is Array[String].
static func finish(tree: SceneTree, token: String, fails: Array) -> void:
	if fails.is_empty():
		print("%s: PASS" % token)
	else:
		print("%s: FAIL %s" % [token, str(fails)])
	tree.quit(0 if fails.is_empty() else 1)


## Prints an ok/FAIL line and appends what to fails when ok is false (shared check helper).
static func check(fails: Array, ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails.append(what)


## Input events for a feature's _unhandled_input: action a pressed.
static func action_event(a: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = true
	return e


## The right trigger at axis value v.
static func trigger_event(v: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = JOY_AXIS_TRIGGER_RIGHT
	e.axis_value = v
	return e


## Physical key k pressed (echo: a key repeat).
static func key_event(k: Key, echo: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.pressed = true
	e.echo = echo
	return e


static func _has_c_lot(sim: CitySim) -> bool:
	for i in sim.active:
		if sim.kind[i] == D.ZONE_C and sim.level[i] >= 1:
			return true
	return false
