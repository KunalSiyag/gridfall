extends SceneTree
## Slice I audio (docs/fp/slices/I-audio.md, acceptance tests): the assets and their loop flags,
## the AudioDirector's tick throttle and on-foot routing, the initial scan, emitter settings, the
## 24-player cap and stealing, manual doppler, horns, sirens, footsteps by surface (polling and the
## stepped signal), ambience beds, settings, the pause muffle, the talk duck, UI cues, crashes,
## knocked props and car doors, the frame budget and teardown. Headless runs the Dummy audio
## driver, so this asserts node state.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const EM := preload("res://scripts/fp/audio/emitters.gd")
const FS := preload("res://scripts/fp/audio/footsteps.gd")
const AMB := preload("res://scripts/fp/audio/ambience.gd")
const DIRECTOR := "res://scripts/audio_director.gd"
const DT := 1.0 / 60.0

var fails: Array[String] = []
var sfx: Array = []           # [path, bus] from the kit director's sfx_played


func _init() -> void:
	await process_frame
	_check_assets()
	await _check_director_throttle()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "audio": true})
	ctx.audio.sfx_played.connect(func(path: String, bus: String) -> void: sfx.append([path, bus]))
	var fx := _fixtures(ctx)
	var f: FpFeature = K.make_feature(ctx, "audio")
	f.set_process(false)
	_check_initial_scan(ctx, f, fx)
	_check_emitter_settings(f)
	_check_cap(ctx, f)
	_check_doppler_and_horns(ctx, f)
	_check_walkers(ctx, f)
	_check_sirens(ctx, f)
	_check_footsteps(ctx, f)
	_check_ambience(ctx, f, fx)
	_check_weather(ctx, f)
	await _check_director_fp(ctx)
	_check_settings(ctx, f)
	_check_pause_and_duck(ctx, f)
	_check_ui(ctx, f)
	_check_impacts(ctx, f)
	_check_doors(ctx, f)
	_check_budget(ctx, f)
	var st: Dictionary = f.self_test()
	K.check(fails, bool(st["ok"]), "self_test: %s" % st["detail"])
	_check_teardown(ctx, f)
	K.finish(self, "FP_AUDIO_TEST", fails)


func _steps(f: FpFeature, seconds: float) -> void:
	for _k in range(roundi(seconds / DT)):
		f.call("step", DT)


func _em(f: FpFeature) -> EM:
	return f.get("emitters")


func _check_assets() -> void:
	var total := 0
	var names := BANK.all_names()
	var bad: Array[String] = []
	for n in names:
		var path := BANK.path_of(n)
		var st := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as AudioStream
		if st == null:
			bad.append(n + " missing")
			continue
		var loops := false
		if st is AudioStreamOggVorbis:
			loops = (st as AudioStreamOggVorbis).loop
		elif st is AudioStreamWAV:
			var w := st as AudioStreamWAV
			loops = w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_end > w.loop_begin
			if w.format != AudioStreamWAV.FORMAT_16_BITS or w.mix_rate != 44100:
				bad.append("%s format %d rate %d" % [n, w.format, w.mix_rate])
		if loops != (n in BANK.LOOPS):
			bad.append("%s loop=%s" % [n, loops])
		if (st is AudioStreamWAV) != BANK.is_wav(n):
			bad.append(n + " container")
		var fa := FileAccess.open(path, FileAccess.READ)
		total += fa.get_length() if fa != null else 0
	K.check(fails, bad.is_empty(), "assets: %d sounds load, loops loop and one-shots do not %s" % [names.size(), str(bad) if not bad.is_empty() else ""])
	K.check(fails, total > 0 and total <= 8 * 1024 * 1024, "assets: sounds/fp is %.2f MB (<= 8 MB)" % (total / 1048576.0))
	var legacy := load(BANK.LEGACY_AMBIENCE) as AudioStreamOggVorbis
	var dup := BANK.legacy_ambience_loop() as AudioStreamOggVorbis
	K.check(fails, legacy != null and dup != null and dup != legacy and dup.loop and not legacy.loop, "assets: the reused ambience.ogg loops as a duplicate; the original keeps loop=false")


func _check_director_throttle() -> void:
	var dir: GridFallAudioDirector = (load(DIRECTOR) as GDScript).new()
	get_root().add_child(dir)
	await process_frame
	var ticks: Array[int] = [0]
	dir.sfx_played.connect(func(path: String, _bus: String) -> void:
		if path == dir.SFX_TICK_PATH:
			ticks[0] += 1)
	for _k in range(50):
		dir.set_blackout_intensity(0.1, "NOMINAL")
	K.check(fails, ticks[0] <= 1, "director: 50 set_blackout_intensity calls -> %d tick (<= 1)" % ticks[0])
	dir.set_blackout_intensity(0.45, "WARNING")
	K.check(fails, ticks[0] <= 1, "director: a phase change inside 10 s does not tick again (%d)" % ticks[0])
	dir.queue_free()
	await process_frame


## A construction site and a live incident near the player, made before the feature exists.
func _fixtures(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	sim.construction_mode = "staged"
	var here := ctx.player_position()
	var best: Array = []
	var bd := INF
	for lot: Array in sim.open_lots(0, 200):
		var d := Vector2(float(lot[0]) - here.x, float(lot[1]) - here.z).length()
		if d < bd and d > 1.5:
			bd = d
			best = lot
	var site := -1
	if not best.is_empty():
		var res := sim.apply_action(0, {"type": "build", "building": "police", "x": int(best[0]), "y": int(best[1])})
		site = D.idx(int(res.get("x", -999)), int(res.get("y", -999))) if bool(res.get("ok", false)) else -1
	K.check(fails, site >= 0 and sim.sites.has(site), "fixture: a construction site before the feature (%d, %.1f u away)" % [site, bd])
	var ev := sim.trigger_disaster("car_crash", roundi(here.x), roundi(here.z), "test")
	K.check(fails, not ev.is_empty(), "fixture: a live incident before the feature")
	return {"site": site, "event": ev}


func _check_initial_scan(ctx: FpContext, f: FpFeature, fx: Dictionary) -> void:
	var em := _em(f)
	f.call("step", DT)
	var site_src: EM.Src = em.source("site:%d" % int(fx["site"]))
	var ev_src: EM.Src = em.source("evs:%d" % int((fx["event"] as Dictionary).get("id", -1)))
	K.check(fails, site_src != null and site_src.player != null, "initial scan: the existing site has a playing emitter")
	K.check(fails, ev_src != null and ev_src.player != null, "initial scan: the existing incident has a siren emitter")
	K.check(fails, em.bank_count() > 0, "initial scan: river bank points (%d)" % em.bank_count())
	# A park built after setup gets a fountain from tile_built.
	var sim := ctx.sim
	sim.construction_mode = "instant"
	var here := ctx.player_position()
	var lots := sim.open_lots(0, 200)
	var park := -1
	for lot: Array in lots:
		if Vector2(float(lot[0]) - here.x, float(lot[1]) - here.z).length() < 6.0:
			var res := sim.apply_action(0, {"type": "build", "building": "park", "x": int(lot[0]), "y": int(lot[1])})
			if bool(res.get("ok", false)):
				park = D.idx(int(lot[0]), int(lot[1]))
				break
	K.check(fails, park >= 0 and sim.kind[park] == D.PARK and em.has_source("foun:%d" % park), "tile_built: a new park registers a fountain (%d)" % park)


func _check_emitter_settings(f: FpFeature) -> void:
	_steps(f, 0.5)
	var maxes := {}
	for t: String in EM.TYPES.keys():
		maxes[float(EM.TYPES[t]["max"])] = true
	var all := f.find_children("*", "AudioStreamPlayer3D", true, false)
	var bad: Array[String] = []
	for n: Node in all:
		var p := n as AudioStreamPlayer3D
		if not is_equal_approx(p.unit_size, WS.AUDIO_UNIT_SIZE):
			bad.append("%s unit_size %.3f" % [p.name, p.unit_size])
		if p.doppler_tracking != AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED:
			bad.append(p.name + " doppler")
		if not maxes.has(p.max_distance):
			bad.append("%s max_distance %.2f" % [p.name, p.max_distance])
		if p.attenuation_model != AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE or p.bus != BANK.BUS_SFX:
			bad.append(p.name + " model/bus")
	for s: EM.Src in _em(f).assigned():
		if not is_equal_approx(s.player.max_distance, float(EM.TYPES[s.type]["max"])):
			bad.append("%s max %.1f" % [s.key, s.player.max_distance])
	K.check(fails, not all.is_empty() and bad.is_empty(), "emitters: %d players, unit_size 0.5, table max_distance, doppler off, SFX bus %s" % [all.size(), str(bad) if not bad.is_empty() else ""])


func _check_cap(_ctx: FpContext, f: FpFeature) -> void:
	var em := _em(f)
	em.agents_provider = func(_p: Vector3, _r: float) -> Array: return []
	em.clear()
	var lis := em.listener()
	var peak := 0
	for k in range(40):
		em.request("t%d" % k, "construction", lis + Vector3(0.15 + 0.17 * k, 0.0, 0.0))
		em.force_refresh()
		f.call("step", DT)
		peak = maxi(peak, f.find_children("*", "AudioStreamPlayer3D", true, false).size())
	var near_ok := true
	for k in range(40):
		var s: EM.Src = em.source("t%d" % k)
		if (s.player != null) != (k < EM.MAX_PLAYERS):
			near_ok = false
	K.check(fails, peak <= EM.MAX_PLAYERS and em.count_assigned() == EM.MAX_PLAYERS, "cap: 40 requests -> %d players at most, %d assigned" % [peak, em.count_assigned()])
	K.check(fails, near_ok, "cap: the 24 nearest hold the players")
	em.request("close", "construction", lis + Vector3(0.0, 0.0, 0.05))
	em.force_refresh()
	f.call("step", DT)
	var far: EM.Src = em.source("t%d" % (EM.MAX_PLAYERS - 1))
	K.check(fails, em.source("close").player != null and far.player == null and em.count_assigned() == EM.MAX_PLAYERS, "cap: a nearer request steals the farthest player")
	em.clear()
	em.full_scan()
	em.rebuild_banks()


func _check_doppler_and_horns(_ctx: FpContext, f: FpFeature) -> void:
	var em := _em(f)
	var agents: Array = [{"id": 77, "off": Vector3(0, 0, 1.0), "vel": Vector3(0, 0, 0.695), "speed": 0.695, "kind": "car", "stalled_s": 0.0}]
	em.agents_provider = func(p: Vector3, r: float) -> Array:
		var out: Array = []
		for a: Dictionary in agents:
			var q: Vector3 = p + a["off"]
			if q.distance_to(p) <= r:
				var d := a.duplicate()
				d["pos"] = q
				out.append(d)
		return out
	_steps(f, 2.0)
	var s: EM.Src = em.source("eng:77")
	var want := EM.engine_pitch(0.695) * 343.0 / (343.0 + 13.9)
	K.check(fails, s != null and s.player != null and absf(s.pitch / want - 1.0) < 0.01 and absf(s.player.pitch_scale / want - 1.0) < 0.01,
		"doppler: receding at 50 km/h -> pitch %.4f (want %.4f)" % [s.pitch if s != null else -1.0, want])
	K.check(fails, s != null and s.stream == BANK.stream("engine_run"), "engines: a moving car plays engine_run")
	agents[0]["vel"] = Vector3(0, 0, -0.695)
	_steps(f, 2.0)
	var up := EM.engine_pitch(0.695) * 343.0 / (343.0 - 13.9)
	K.check(fails, absf(s.pitch / up - 1.0) < 0.01, "doppler: approaching -> pitch %.4f (want %.4f)" % [s.pitch, up])
	# Eight nearest cars at most; idle cars play engine_idle.
	agents.clear()
	for k in range(12):
		agents.append({"id": 100 + k, "off": Vector3(0.2 * (k + 1), 0, 0.1), "vel": Vector3.ZERO, "speed": 0.0, "kind": "car", "stalled_s": 0.0})
	_steps(f, 1.0)
	var engines := 0
	for x: EM.Src in em.sources():
		if x.type == "engine" and not x.dying:
			engines += 1
	K.check(fails, engines == EM.ENGINE_CARS and em.source("eng:100").stream == BANK.stream("engine_idle") and em.source("eng:111") == null,
		"engines: the %d nearest of 12 cars, idle ones on engine_idle (%d)" % [EM.ENGINE_CARS, engines])
	# Horns: a jam honks now and then, never twice within HORN_GAP; none without stalled_s.
	for a: Dictionary in agents:
		a["stalled_s"] = 30.0
	var h0 := em.horns_played
	var times: Array[float] = []
	for k in range(roundi(60.0 / DT)):
		var before := em.horns_played
		f.call("step", DT)
		if em.horns_played > before:
			times.append(k * DT)
	var gap_ok := true
	for k in range(1, times.size()):
		if times[k] - times[k - 1] < EM.HORN_GAP - 0.01:
			gap_ok = false
	K.check(fails, em.horns_played - h0 >= 2 and gap_ok, "horns: %d horns in 60 s from a jam, >= %.0f s apart" % [em.horns_played - h0, EM.HORN_GAP])
	# One stalled car rests between its own horns; a car that just stopped never honks.
	var lone: Dictionary = agents[0]
	agents.clear()
	agents.append(lone)
	var h_lone := em.horns_played
	_steps(f, 60.0)
	K.check(fails, em.horns_played - h_lone <= ceili(60.0 / EM.HORN_CAR_REST), "horns: one stalled car honks %d times in 60 s (<= %d)" % [em.horns_played - h_lone, ceili(60.0 / EM.HORN_CAR_REST)])
	lone["stalled_s"] = EM.HORN_STALL_S
	var h_fresh := em.horns_played
	_steps(f, 30.0)
	K.check(fails, em.horns_played == h_fresh, "horns: none from a car stalled only %.0f s" % EM.HORN_STALL_S)
	for a: Dictionary in agents:
		a.erase("stalled_s")
	var h1 := em.horns_played
	_steps(f, 30.0)
	K.check(fails, em.horns_played == h1, "horns: none while agents lack stalled_s")
	em.agents_provider = Callable()
	_steps(f, 1.0)


## Residents walking past within 6 m step audibly (the WALKER_MAX nearest, one step per stride);
## farther walkers and E's bikes (reported as "pedestrian") stay silent.
func _check_walkers(ctx: FpContext, f: FpFeature) -> void:
	var em := _em(f)
	var hero := ctx.player_position()
	var walk := 1.35 * WS.M
	var t: Array[float] = [0.0]
	var agents: Array = []
	for k in range(6):
		agents.append({"id": 2000 + k, "start": hero + Vector3(0.05 + 0.04 * k, 0, -0.1), "vel": Vector3(0, 0, walk), "speed": walk, "kind": "pedestrian", "stalled_s": 0.0})
	agents.append({"id": 2100, "start": hero + Vector3(0.5, 0, -0.1), "vel": Vector3(0, 0, walk), "speed": walk, "kind": "pedestrian", "stalled_s": 0.0})
	agents.append({"id": 2101, "start": hero + Vector3(-0.04, 0, -0.1), "vel": Vector3(0, 0, 5.0 * WS.M), "speed": 5.0 * WS.M, "kind": "pedestrian", "stalled_s": 0.0})
	em.agents_provider = func(p: Vector3, r: float) -> Array:
		var out: Array = []
		for a: Dictionary in agents:
			var q: Vector3 = (a["start"] as Vector3) + (a["vel"] as Vector3) * t[0]
			if q.distance_to(p) <= r:
				var d := a.duplicate()
				d["pos"] = q
				out.append(d)
		return out
	var s0 := em.walker_steps
	var heard := {}
	var near_ok := true
	for _k in range(roundi(3.0 / DT)):
		t[0] += DT
		f.call("step", DT)
		var ws: Dictionary = em.get("_walkers")
		for id: String in ws.keys():
			heard[id] = true
		for s: EM.Src in em.sources():
			if s.type == "step" and Vector2(s.pos.x - hero.x, s.pos.z - hero.z).length() > EM.WALKER_RADIUS + 0.02:
				near_ok = false
	var n := em.walker_steps - s0
	var ids := heard.keys()
	ids.sort()
	K.check(fails, ids == ["2000", "2001", "2002", "2003"] and near_ok, "walkers: the %d nearest residents within 6 m step, the far one and the cyclist do not (%s)" % [EM.WALKER_MAX, str(ids)])
	K.check(fails, n >= 16 and n <= 28, "walkers: 4 residents walking 3 s at 1.35 m/s -> %d steps (one per 0.7 m stride, ~23)" % n)
	em.agents_provider = Callable()
	_steps(f, 1.0)
	K.check(fails, (em.get("_walkers") as Dictionary).is_empty(), "walkers: forgotten once no agents report them")


func _check_sirens(ctx: FpContext, f: FpFeature) -> void:
	var em := _em(f)
	var sim := ctx.sim
	for ev: Dictionary in sim.events.duplicate():
		sim.resolve_incident(ev, "test")
	_steps(f, 2.0)
	sfx.clear()
	var here := ctx.player_position()
	var ev := sim.trigger_disaster("fire", roundi(here.x), roundi(here.z), "test")
	ctx.audio.play_sfx("res://sounds/gridlock_alert.wav", -6.0)   # main.gd's event_started cue
	f.call("step", DT)
	f.call("step", DT)
	K.check(fails, not ev.is_empty() and em.count_assigned("siren") >= 1, "sirens: a fire has a siren emitter within 2 frames (%d)" % em.count_assigned("siren"))
	var alerts := 0
	for e: Array in sfx:
		if str(e[0]) == "res://sounds/gridlock_alert.wav":
			alerts += 1
	K.check(fails, alerts == 0, "sirens: on foot the director does not play gridlock_alert (%d)" % alerts)
	_steps(f, 1.0)
	var burning := 0
	for i in sim.active:
		if sim.burning[i] > 0:
			burning += 1
	K.check(fails, em.count_assigned("fire") >= 1, "fire: a crackle at the burning tile (%d burning)" % burning)
	sim.resolve_incident(ev, "test")
	var t := 0.0
	while t < 10.0 and (em.count_assigned("siren") > 0 or em.has_source("evs:%d" % int(ev.get("id", -1)))):
		f.call("step", DT)
		t += DT
	K.check(fails, em.count_assigned("siren") == 0 and not em.has_source("evs:%d" % int(ev.get("id", -1))), "sirens: event_ended frees the siren (%.2f s)" % t)


## A soft landing adds no step of its own (its stepped already played); a heavy one adds the
## other foot.
func _check_landings(fs: FS, p: Node3D) -> void:
	var n := fs.steps_played
	var h := fs.heavy_lands
	p.emit_signal("landed", 3.4)
	var soft_ok := fs.steps_played == n and fs.heavy_lands == h
	p.emit_signal("landed", 6.0)
	var heavy_ok := fs.steps_played == n + 1 and fs.heavy_lands == h + 1
	var msg := "footsteps: a soft landing adds nothing, a heavy one the other foot"
	var got := [msg, fs.steps_played - n, fs.heavy_lands - h]
	K.check(fails, soft_ok and heavy_ok, "%s (%d steps, %d heavy)" % got)


func _check_footsteps(ctx: FpContext, f: FpFeature) -> void:
	var fs: FS = f.get("footsteps")
	var sim := ctx.sim
	var col := ctx.collision
	var road := -1
	var park := -1
	for i in sim.active:
		if road < 0 and sim.kind[i] == D.ROAD and not RoadTopology.is_bridge(sim, i):
			var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
			if RoadTopology.piece(m)[0] == "straight":
				road = i
		if park < 0 and sim.kind[i] == D.PARK:
			park = i
	var cases := [["asphalt", Vector3(D.tx(road), 0, D.ty(road))], ["sidewalk", RoadTopology.sidewalk_point(sim, road, 1)], ["grass", Vector3(D.tx(park), 0, D.ty(park))]]
	for c: Array in cases:
		var surf := col.surface_at(c[1])
		fs.play(surf)
		var last: String = fs.history.back()
		K.check(fails, surf == c[0] and last.begins_with("footstep_%s_" % c[0]), "footsteps: %s -> %s plays %s" % [str(c[1]), surf, last])
	# Polling: a walker without a stepped signal (FpPlayer has one since slice A).
	var p := ctx.player
	p.teleport(Vector3(D.tx(road), 0, D.ty(road)), 0.0)
	var walker := Node3D.new()
	walker.name = "PollStub"
	get_root().add_child(walker)
	walker.position = p.position
	fs.bind(walker)
	var n0 := fs.steps_played
	var travel := 10.0 * FS.STRIDE_M * WS.M
	var inc := 0.1 * WS.M
	fs.poll(DT)
	for _k in range(roundi(travel / inc)):
		walker.position.x += inc
		fs.poll(DT)
	var polled := fs.steps_played - n0
	K.check(fails, fs.polling and absi(polled - 10) <= 1, "footsteps: polling, 10 strides of travel -> %d steps" % polled)
	# The player with its stepped signal: one step per emission, no polling.
	var sp := p
	fs.bind(sp)
	var n1 := fs.steps_played
	for _k in range(8):
		sp.emit_signal("stepped", "sidewalk", sp.position)
	var alt := true
	var hist := fs.history.slice(fs.history.size() - 8)
	for k in range(1, hist.size()):
		if FS.is_left_variant(hist[k]) == FS.is_left_variant(hist[k - 1]):
			alt = false
	K.check(fails, not fs.polling and fs.steps_played - n1 == 8 and alt, "footsteps: 8 stepped emissions -> %d steps, alternating feet %s" % [fs.steps_played - n1, str(hist)])
	_check_landings(fs, sp)
	var n2 := fs.steps_played
	for _k in range(roundi(travel / inc)):
		sp.position.x += inc
		fs.poll(DT)
	K.check(fails, fs.steps_played == n2, "footsteps: walking with the signal but no emission plays nothing")
	fs.bind(p)
	walker.queue_free()


func _check_ambience(ctx: FpContext, f: FpFeature, _fx: Dictionary) -> void:
	var amb: AMB = f.get("ambience")
	var sim := ctx.sim
	var here := ctx.player_position()
	var bank := Vector3(NAN, 0, NAN)
	var bd := INF
	var green := Vector3(NAN, 0, NAN)
	var gd := INF
	var down := Vector3(NAN, 0, NAN)
	var dd := INF
	for y in range(-40, 72):
		for x in range(-40, 72):
			var i := D.idx(x, y)
			var dist := Vector2(x - here.x, y - here.z).length()
			if sim.terrain[i] == D.LAND and sim.kind[i] == D.EMPTY and dist < bd:
				for dv: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if D.in_bounds(x + dv.x, y + dv.y) and sim.terrain[D.idx(x + dv.x, y + dv.y)] == D.WATER and sim.kind[D.idx(x + dv.x, y + dv.y)] != D.ROAD:
						bd = dist
						bank = Vector3(x + dv.x * 0.3, 0, y + dv.y * 0.3)
			if (sim.kind[i] == D.PARK or sim.kind[i] == D.FOREST) and dist < gd:
				gd = dist
				green = Vector3(x, 0, y)
			if (sim.kind[i] == D.ZONE_C or sim.kind[i] == D.ZONE_I) and sim.level[i] > 0 and dist < dd:
				dd = dist
				down = Vector3(x, 0, y)
	K.check(fails, not is_nan(bank.x) and not is_nan(green.x) and not is_nan(down.x), "fixture: a river bank %s, green %s and downtown %s" % [bank, green, down])
	if is_nan(bank.x) or is_nan(green.x) or is_nan(down.x):
		return
	var p := ctx.player
	var most := 0
	var path: Array[Vector3] = [green, bank, down]
	var river_top := false
	for k in range(path.size()):
		p.teleport(path[k], 0.0)
		ctx.bus.player_tile_changed.emit(roundi(path[k].x), roundi(path[k].z))
		for _s in range(roundi(3.0 / DT)):
			f.call("step", DT)
			most = maxi(most, amb.playing_count())
		if k == 1:
			var w: Dictionary = amb.weights
			river_top = amb.loudest() == "river" and float(w["river"]) >= float(w[w.keys().reduce(func(a: Variant, b: Variant) -> Variant: return a if float(w[a]) >= float(w[b]) else b)])
			K.check(fails, river_top, "ambience: by the water the river bed is the largest after 3 s (%s, levels %s)" % [amb.loudest(), str(amb.levels)])
		if k == 0:
			K.check(fails, float(amb.levels["park_birds"]) > 0.05, "ambience: birds in the green (%s)" % str(amb.levels))
		if k == 2:
			K.check(fails, amb.loudest() == "traffic_hum", "ambience: traffic hum downtown (%s)" % str(amb.levels))
	K.check(fails, most <= AMB.MAX_PLAYING and amb.max_seen_playing <= AMB.MAX_PLAYING, "ambience: at most %d beds played at once (%d)" % [AMB.MAX_PLAYING, most])
	var res: AudioStreamPlayer = amb.players["residential_quiet"]
	K.check(fails, res.stream == BANK.legacy_ambience_loop() and (res.stream as AudioStreamOggVorbis).loop and not (load(BANK.LEGACY_AMBIENCE) as AudioStreamOggVorbis).loop, "ambience: the residential bed plays the looping duplicate of ambience.ogg")
	p.teleport(here, 0.0)
	ctx.bus.player_tile_changed.emit(roundi(here.x), roundi(here.z))


## G1's weather, read by name from a stand-in streetscape feature: rain fades a rain bed in and the
## birds out, and steps on soaked paving get a splash layer (not on grass).
func _check_weather(ctx: FpContext, f: FpFeature) -> void:
	var amb: AMB = f.get("ambience")
	var fs: FS = f.get("footsteps")
	var wg := GDScript.new()
	wg.source_code = "extends RefCounted\nvar state: String = \"rain\"\nvar wet: float = 0.9\n"
	wg.reload()
	var sg := GDScript.new()
	sg.source_code = "extends FpFeature\nvar weather: RefCounted\n"
	sg.reload()
	var street: FpFeature = sg.new()
	var w: RefCounted = wg.new()
	street.set("weather", w)
	ctx.features["streetscape"] = street
	amb.recompute()
	var most := 0
	for _s in range(roundi(4.0 / DT)):
		f.call("step", DT)
		most = maxi(most, amb.playing_count())
	var rain_p: AudioStreamPlayer = amb.players["rain"]
	K.check(fails, amb.weather_state() == "rain" and rain_p.playing and float(amb.levels["rain"]) > 0.6 and rain_p.bus == BANK.BUS_AMBIENCE and most <= AMB.MAX_PLAYING,
		"weather: rain fades the rain bed in (level %.2f, %d beds)" % [float(amb.levels["rain"]), most])
	var sp0 := fs.splashes_played
	fs.play("asphalt")
	fs.play("sidewalk")
	var sp1 := fs.splashes_played
	fs.play("grass")
	K.check(fails, sp1 - sp0 == 2 and fs.splashes_played == sp1, "weather: steps on soaked paving splash, steps on grass do not")
	w.set("state", "clear")
	w.set("wet", 0.0)
	amb.recompute()
	_steps(f, 4.0)
	fs.play("asphalt")
	K.check(fails, not rain_p.playing and float(amb.levels["rain"]) == 0.0 and fs.splashes_played == sp1, "weather: the rain bed stops when it clears, and dry steps do not splash")
	ctx.features.erase("streetscape")
	street.free()
	amb.recompute()


func _check_director_fp(ctx: FpContext) -> void:
	var dir: GridFallAudioDirector = ctx.audio
	var nom := dir.get_node("NominalStemPlayer") as AudioStreamPlayer
	var cri := dir.get_node("CrisisStemPlayer") as AudioStreamPlayer
	var sfxp := dir.get_node("SfxPlayer") as AudioStreamPlayer
	K.check(fails, dir.is_fp() and nom.bus == &"Music" and cri.bus == &"Music" and sfxp.bus == &"UI" and dir.process_mode == Node.PROCESS_MODE_ALWAYS, "director: on foot the stems use Music, cues use UI, and it runs while paused")
	await process_frame
	var mix: float = dir.get("_current_mix")
	var want_nom := linear_to_db(clampf(1.0 - mix * 0.85, 0.05, 1.0)) - 4.0
	var want_cri := linear_to_db(clampf(0.04 + mix * 0.96, 0.02, 1.0)) - 3.0
	K.check(fails, absf(nom.volume_db - (want_nom - 8.0)) < 0.05 and absf(cri.volume_db - (want_cri - 8.0)) < 0.05, "director: stems 8 dB under the orbit mix (%.2f / %.2f)" % [nom.volume_db - want_nom, cri.volume_db - want_cri])
	sfx.clear()
	dir.play_sfx("res://sounds/day_bell.wav", -12.0)
	K.check(fails, sfx.size() == 1 and str(sfx[0][1]) == "UI" and is_equal_approx(sfxp.volume_db, -18.0), "director: day_bell on the UI bus 6 dB quieter (%s, %.1f dB)" % [str(sfx), sfxp.volume_db])
	dir.set_fp(false)
	await process_frame
	mix = dir.get("_current_mix")
	want_nom = linear_to_db(clampf(1.0 - mix * 0.85, 0.05, 1.0)) - 4.0
	want_cri = linear_to_db(clampf(0.04 + mix * 0.96, 0.02, 1.0)) - 3.0
	K.check(fails, nom.bus == &"Master" and cri.bus == &"Master" and sfxp.bus == &"Master" and dir.process_mode == Node.PROCESS_MODE_INHERIT
		and absf(nom.volume_db - want_nom) < 0.05 and absf(cri.volume_db - want_cri) < 0.05, "director: set_fp(false) restores the orbit buses, volumes and process mode")
	sfx.clear()
	dir.play_sfx("res://sounds/gridlock_alert.wav", -6.0)
	K.check(fails, sfx.size() == 1, "director: orbit still plays gridlock_alert")
	dir.set_fp(true)


func _check_settings(ctx: FpContext, f: FpFeature) -> void:
	ctx.bus.settings_changed.emit({"music_volume_db": -20.0, "sfx_volume_db": -3.0})
	var m := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(&"Music"))
	var s := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(&"SFX"))
	var a := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(&"Ambience"))
	K.check(fails, is_equal_approx(m, -20.0) and is_equal_approx(s, -3.0) and is_equal_approx(a, -3.0), "settings: Music %.1f, SFX %.1f, Ambience %.1f dB" % [m, s, a])
	ctx.bus.settings_changed.emit({"music_volume_db": 0.0, "sfx_volume_db": 0.0})
	var routed := true
	for b in ["Music", "SFX", "Ambience", "UI"]:
		var i := AudioServer.get_bus_index(b)
		routed = routed and i > 0 and AudioServer.get_bus_send(i) == &"Master"
	K.check(fails, routed, "buses: Music, SFX, Ambience and UI route to Master")
	f.call("step", DT)


func _check_pause_and_duck(ctx: FpContext, f: FpFeature) -> void:
	var lp: AudioEffectLowPassFilter = f.get("music_filter")
	var mi := AudioServer.get_bus_index(&"Music")
	var on_music := false
	for k in range(AudioServer.get_bus_effect_count(mi)):
		on_music = on_music or AudioServer.get_bus_effect(mi, k) == lp
	K.check(fails, lp != null and on_music and is_equal_approx(lp.cutoff_hz, 20000.0), "pause: a 20 kHz low-pass on the Music bus")
	ctx.bus.pause_changed.emit(true)
	(f.get("_muffle") as Tween).custom_step(1.0)
	var paused := lp.cutoff_hz
	ctx.bus.pause_changed.emit(false)
	(f.get("_muffle") as Tween).custom_step(1.0)
	K.check(fails, is_equal_approx(paused, 800.0) and is_equal_approx(lp.cutoff_hz, 20000.0), "pause: the music muffles to %.0f Hz and opens again (%.0f Hz)" % [paused, lp.cutoff_hz])
	var ai := AudioServer.get_bus_index(&"Ambience")
	ctx.bus.conversation_changed.emit("r_test", true)
	_steps(f, 1.0)
	var ducked := AudioServer.get_bus_volume_db(ai)
	ctx.bus.conversation_changed.emit("r_test", false)
	_steps(f, 1.0)
	K.check(fails, is_equal_approx(ducked, -6.0) and is_equal_approx(AudioServer.get_bus_volume_db(ai), 0.0), "talk: the beds duck 6 dB while talking (%.1f) and come back" % ducked)


func _check_ui(ctx: FpContext, f: FpFeature) -> void:
	_steps(f, 2.0)
	var b0: int = f.get("blips_played")
	var msg := {"seq": 1, "author_id": "r1", "author": "Ana", "role": "resident", "district": 0, "text": "hi", "kind": "chatter", "day": 1, "clock": "08:00", "t_ms": 0, "reply_to": -1, "refs": {}}
	ctx.bus.chat_posted.emit(msg)
	ctx.bus.chat_posted.emit(msg)
	var b1: int = f.get("blips_played")
	_steps(f, 1.6)
	var mine := msg.duplicate()
	mine["role"] = "player"
	ctx.bus.chat_posted.emit(mine)
	var b2: int = f.get("blips_played")
	var sys := msg.duplicate()
	sys["role"] = "system"
	sys["kind"] = "alert"
	ctx.bus.chat_posted.emit(sys)
	var ui: Array = f.get("_ui")
	var soft := false
	for p: AudioStreamPlayer in ui:
		soft = soft or p.stream == BANK.stream("chat_blip_soft")
	K.check(fails, b1 - b0 == 1 and b2 == b1 and int(f.get("blips_played")) == b1 + 1 and soft and str(f.get("last_blip")) == "card",
		"chat: one blip per 1.5 s, none for the player's own line, the soft blip for an alert card")
	# The drip releases a line every 1.5-3 s: ordinary lines share one blip per CHATTER_GAP, while a
	# reply to the player's own line always gets the full blip.
	_steps(f, 1.6)
	var b3: int = f.get("blips_played")
	ctx.bus.chat_posted.emit(msg)
	var b4: int = f.get("blips_played")
	var reply := msg.duplicate()
	reply["seq"] = 7
	reply["reply_to"] = int(mine["seq"])
	ctx.bus.chat_posted.emit(reply)
	var full := false
	for p: AudioStreamPlayer in ui:
		full = full or p.stream == BANK.stream("chat_blip")
	K.check(fails, b4 == b3 and int(f.get("blips_played")) == b4 + 1 and str(f.get("last_blip")) == "reply" and full,
		"chat: more chatter inside the chatter gap stays silent, a reply to the player gets the full blip (%s)" % str(f.get("last_blip")))
	var s0: int = f.get("stingers_played")
	ctx.bus.ping.emit(Vector3.ZERO, "event:fire")
	ctx.bus.toast.emit("Fire!", "alert")
	ctx.bus.ping.emit(Vector3.ZERO, "resident:r1")
	K.check(fails, int(f.get("stingers_played")) - s0 == 1, "alerts: an event ping plays the stinger once (toasts within 4 s share it)")


## car_impact plays a crash at the contact (a bump below CRASH_MPS, quieter), prop_knocked the
## prop's own clatter (at most one per KNOCK_GAP); each one-shot gets a player and starts.
func _check_impacts(ctx: FpContext, f: FpFeature) -> void:
	var em := _em(f)
	var at := em.listener() + Vector3(0.1, 0.0, 0.0)
	var hard := _shot(f, func() -> void: ctx.bus.car_impact.emit(at, 10.0 * WS.M, "wall"))
	var soft := _shot(f, func() -> void: ctx.bus.car_impact.emit(at, 3.0 * WS.M, "car"))
	K.check(
		fails,
		_is_shot(hard, "crash", "crash_heavy") and _is_shot(soft, "crash", "crash_light"),
		"impacts: a 10 m/s hit plays crash_heavy, a 3 m/s bump crash_light, both started"
	)
	K.check(
		fails,
		hard != null and soft != null and soft.db < hard.db and hard.db <= EM.TYPES["crash"]["db"],
		"impacts: the bump is quieter (%.1f dB < %.1f dB)" % [soft.db, hard.db]
	)
	var bin := _shot(f, func() -> void: ctx.bus.prop_knocked.emit(at, "bin", 5.0 * WS.M))
	var n := em.shots_played
	ctx.bus.prop_knocked.emit(at, "bin", 5.0 * WS.M)
	var again := em.shots_played - n
	_steps(f, BANK.KNOCK_GAP + 0.05)
	var box := _shot(f, func() -> void: ctx.bus.prop_knocked.emit(at, "mailbox", 4.0 * WS.M))
	K.check(
		fails,
		(
			_is_shot(bin, "knock", "prop_clatter")
			and again == 0
			and _is_shot(box, "knock", "prop_clang")
		),
		"impacts: a knocked bin clatters, a second at once stays silent, a mailbox clangs"
	)
	_steps(f, 3.5)


## car_door plays at the door: the latch as it opens (DOOR_OPEN_DB under the slam), the slam as
## it shuts.
func _check_doors(ctx: FpContext, f: FpFeature) -> void:
	var at := _em(f).listener() + Vector3(0.05, 0.0, 0.0)
	var open := _shot(f, func() -> void: ctx.bus.car_door.emit(at, true))
	var slam := _shot(f, func() -> void: ctx.bus.car_door.emit(at, false))
	K.check(
		fails,
		_is_shot(open, "door", "car_door_open") and _is_shot(slam, "door", "car_door_close"),
		"car doors: opening plays car_door_open, shutting car_door_close, both started"
	)
	K.check(
		fails,
		open != null and slam != null and is_equal_approx(open.db, slam.db + BANK.DOOR_OPEN_DB),
		"car doors: the latch plays under the slam (%.1f dB, %.1f dB)" % [
			open.db if open != null else NAN, slam.db if slam != null else NAN
		]
	)
	_steps(f, 3.5)


## The one-shot that fire() starts (after one step), or null.
func _shot(f: FpFeature, fire: Callable) -> EM.Src:
	var em := _em(f)
	var n := em.shots_played
	fire.call()
	var s: EM.Src = em.source("shot:%d" % em.shots_played) if em.shots_played == n + 1 else null
	f.call("step", DT)
	return s


func _is_shot(s: EM.Src, type: String, stream_name: String) -> bool:
	return s != null and s.type == type and s.stream == BANK.stream(stream_name) and s.started


func _check_budget(ctx: FpContext, f: FpFeature) -> void:
	var p := ctx.player
	var times: Array[float] = []
	for k in range(600):
		p.position.x += 0.0004
		var t0 := Time.get_ticks_usec()
		f.call("step", DT)
		times.append(float(Time.get_ticks_usec() - t0))
	times.sort()
	var p50 := times[times.size() / 2]
	var avg := 0.0
	for t in times:
		avg += t
	avg /= times.size()
	print("  budget: step avg %.0f us, p50 %.0f us, p99 %.0f us, max %.0f us" % [avg, p50, times[int(times.size() * 0.99)], times.back()])
	K.check(fails, avg < 300.0, "budget: audio step averages %.0f us (< 300 us)" % avg)
	# A grown city registers hundreds of static sources (a fountain per park, every site): the
	# per-frame cost must not grow with them.
	var em := _em(f)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var here := ctx.player_position()
	for k in range(300):
		em.request("budget:%d" % k, "fountain", here + Vector3(rng.randf_range(-40.0, 40.0), 0.0, rng.randf_range(-40.0, 40.0)))
	var big: Array[float] = []
	for k in range(600):
		p.position.x += 0.0004
		var t0 := Time.get_ticks_usec()
		f.call("step", DT)
		big.append(float(Time.get_ticks_usec() - t0))
	var avg_big := 0.0
	for t in big:
		avg_big += t
	avg_big /= big.size()
	for k in range(300):
		em.release("budget:%d" % k)
	_steps(f, 1.5)
	K.check(fails, avg_big < 300.0, "budget: with 300 more static sources the step averages %.0f us (was %.0f)" % [avg_big, avg])


func _check_teardown(ctx: FpContext, f: FpFeature) -> void:
	f.teardown()
	var gone := true
	for b in ["Music", "SFX", "Ambience", "UI"]:
		gone = gone and AudioServer.get_bus_index(b) < 0
	var nom := ctx.audio.get_node("NominalStemPlayer") as AudioStreamPlayer
	K.check(fails, gone and not ctx.audio.is_fp() and nom.bus == &"Master" and _em(f).count_assigned() == 0, "teardown: buses removed, director back to orbit, emitters stopped")
