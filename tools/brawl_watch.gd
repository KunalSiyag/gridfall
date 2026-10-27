extends SceneTree
## A slow look at one brawl the fight_tempers feature makes (tools/combat_proof.gd proves the
## single fight; the unit tests prove the rules): five people of a known temper in a ring around
## the hero, one jab each, then thirty seconds of scrap while the hero covers up and cannot be
## hurt. A frame every few seconds plus a per-second state line show who squares up, hangs back,
## joins in or thinks better of it. Then the downed_awareness beats: a hard blow leaves an
## onlooker down and the nearest of the rest walks over and leans in a moment (check_lean), and
## the hero takes a fall with the scrap still on, so the fighter stands over them a beat before
## walking off (stand_over). The ring stands off the road network, so a run shows its pose
## without carrying the runner far; on the street it would. Stands on the shared proof bench
## (tools/proof_kit.gd). Run:
##   godot --path . --resolution 1600x900 -s tools/brawl_watch.gd -- --output=<dir>

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const PK := preload("res://tools/proof_kit.gd")
const DT := 1.0 / 60.0
const WATCH_S := 30.0
const SHOT_EVERY := 3.0
const LOG_EVERY := 1.0
## The ring's tempers in the order they stand around the hero: one of each kind.
const TEMPER_NAMES := {
	RE.T_PLAIN: "plain",
	RE.T_GUARD: "guard",
	RE.T_DANCER: "dancer",
	RE.T_CALLER: "caller",
	RE.T_BOLT: "bolt",
	RE.T_BRUISER: "bruiser",
}
## [temper, metres from the hero, radians around them] for the ring.
const FIGHTERS := [
	[RE.T_GUARD, 1.4, 0.2],
	[RE.T_DANCER, 1.6, 1.3],
	[RE.T_CALLER, 1.3, 2.4],
	[RE.T_BRUISER, 1.5, 3.5],
	[RE.T_BOLT, 1.4, 4.6],
]
## [metres, radians] for the few onlookers.
const BYSTANDERS := [[4.0, 1.9], [5.0, 3.0], [6.0, 5.5]]

var kit: PK
var actions: FpFeature
var brawl: FpFeature
var health: FpFeature
var fighters: Array = []
var bystanders: Array = []
var _t := 0.0
var _last_log := -LOG_EVERY
## What the shot camera frames: the ring's middle, or the walker lying down (the downed acts);
## how far out it sits and how high up the framed point it looks (metres).
var focus: WK.Walker = null
var cam_range := 2.8
var look_up := 1.05


func _init() -> void:
	await process_frame
	kit = PK.new()
	kit.tag = "BRAWL_WATCH"
	kit.bench(self, "/tmp/gf-brawl-watch")
	kit.ctx.player.input_enabled = true
	actions = K.make_feature(kit.ctx, "actions")
	brawl = K.make_feature(kit.ctx, "brawl")
	health = K.make_feature(kit.ctx, "health")
	for f: FpFeature in [actions, brawl, health]:
		f.set_process(false)
	kit.traffic.set("auto_step", false)
	kit.traffic.set("ambient_enabled", false)
	(kit.traffic.get("people") as RefCounted).set("blocking", true)
	kit.per_frame = _on_frame
	_stage()
	# Two clocks before the jabs: the traffic step is what opens the hero to a fight, and the
	# scrap's plan is fixed the moment a blow lands.
	await kit.settle(2)
	_hits()
	actions.call("set_guard", true)
	for s in range(1, int(WATCH_S / SHOT_EVERY) + 1):
		await kit.settle(int(SHOT_EVERY / DT))
		await kit.shot("watch_%02d" % s)
	await _act_check()
	await _act_stand_over()
	kit.finish()


## The staged ring: five fighters of a known temper an arm's length out, a few bystanders
## farther off, and the hero at the middle of it.
func _stage() -> void:
	var react: Object = kit.traffic.get("reactions")
	react.set("fight_odds", {"punch": 1.0, "shove": 1.0})
	var pins := {}
	var wk: Object = kit.traffic.get("walkers")
	for spec: Array in FIGHTERS:
		var w: WK.Walker = wk.make("ambient")
		w.resident_id = "watch-%d" % w.id
		wk.stand(w, _ring_at(spec[2], spec[1]), spec[2] + PI)
		w.state = "walk"
		pins[w.id] = spec[0]
		fighters.append(w)
	react.set("fight_temper", pins)
	for spec: Array in BYSTANDERS:
		var b: WK.Walker = wk.make("ambient")
		b.resident_id = "watch-%d" % b.id
		wk.stand(b, _ring_at(spec[1], spec[0]), spec[1] + PI)
		bystanders.append(b)
	kit.ctx.player.teleport(Vector3.ZERO, 0.0)


## The spot metres out at the given angle around the hero.
func _ring_at(angle: float, metres: float) -> Vector3:
	return Vector3(sin(angle), 0.0, cos(angle)) * (metres * WS.M)


## One jab each to start the scrap.
func _hits() -> void:
	for w: WK.Walker in fighters:
		kit.traffic.call(
			"hit_walker", w.id, Vector3.ZERO, w.pos.normalized() * (0.5 * WS.M), 0.3, "punch"
		)


## The first downed beat (downed_awareness): a hard blow leaves the nearest bystander down out
## on the grass, and whoever of the rest is nearest walks over and leans in over them.
func _act_check() -> void:
	focus = bystanders[0]
	cam_range = 2.3
	look_up = 0.55
	var v: WK.Walker = bystanders[0]
	kit.traffic.call(
		"hit_walker",
		v.id,
		v.pos - Vector3(WS.M, 0.0, 0.0),
		Vector3(0.5 * WS.M, 0.0, 0.0),
		1.0,
		"car"
	)
	var leaned := await _until(func() -> bool: return _leaning_one() != null, 6.0)
	if leaned:
		await kit.settle(30)
		await kit.shot("check_lean")
	else:
		kit.fail("nobody came to look at the one who went down")
	await _until(func() -> bool: return _leaning_one() == null, 6.0)


## The second downed beat: with the ring re-roused, the hero takes a fall, and the one fighting
## them stands over the body a beat (one last shout) before walking off.
func _act_stand_over() -> void:
	focus = null
	cam_range = 2.4
	look_up = 0.7
	actions.call("set_guard", false)
	var react: Object = kit.traffic.get("reactions")
	var f: WK.Walker = fighters[0]
	kit.traffic.call(
		"hit_walker", f.id, Vector3.ZERO, f.pos.normalized() * (0.5 * WS.M), 0.45, "punch"
	)
	await _until(func() -> bool: return bool(react.call("fighting", f)), 5.0)
	health.call("hurt", 12.0, "punch", Vector3(0.0, 0.0, 0.4 * WS.M), true)
	var over := await _until(
		func() -> bool: return not react.call("fighting", f) and f.react == &"shout", 4.0
	)
	if over:
		await kit.settle(20)
		await kit.shot("stand_over")
	else:
		kit.fail("no stand-over beat when the hero went down")
	await kit.settle(90)


## Settles in short bursts until cond holds or the seconds run out; true when cond held.
func _until(cond: Callable, secs: float) -> bool:
	var t := 0.0
	while t < secs:
		await kit.settle(4)
		if bool(cond.call()):
			return true
		t += 4.0 * DT
	return false


## The one leaning over a body right now (the checker's forward tip), or none.
func _leaning_one() -> WK.Walker:
	for w: WK.Walker in fighters + bystanders:
		if w != focus and w.vis_tilt > 0.2:
			return w
	return null


## One clock of the watch: the fight features tick, the hero's health is pinned so the scrap
## cannot end them, the shot camera re-frames, and each second gets a state line.
func _on_frame() -> void:
	actions.call("tick", DT)
	brawl.call("tick", DT)
	health.set("hp", 100.0)
	health.call("tick", DT)
	_frame_camera()
	_t += DT
	if _t - _last_log >= LOG_EVERY:
		_last_log = _t
		_log_states()


## The camera looks down into the ring from off the hero's shoulder, so the far side of the
## scrap faces it; with a focus (someone down) it closes on where they lie instead.
func _frame_camera() -> void:
	var cam: Camera3D = kit.tree.get_root().get_camera_3d()
	var at := Vector3.ZERO
	if focus != null:
		at = focus.pos + focus.vis_off
	var a := 5.5
	var cam_pos := (
		at + Vector3(sin(a), 0.0, cos(a)) * (cam_range * WS.M) + Vector3(0.0, 2.0 * WS.M, 0.0)
	)
	cam.position = cam_pos
	cam.basis = Basis.looking_at((at + Vector3(0.0, look_up * WS.M, 0.0) - cam_pos).normalized())
	cam.fov = 55.0


## The per-second state line: each fighter's temper, whether they are in the scrap and how far
## they stand, then the same for the bystanders.
func _log_states() -> void:
	var react: Object = kit.traffic.get("reactions")
	var bits: Array[String] = []
	for w: WK.Walker in fighters:
		# The drawn spot (pos + vis_off), not the sim spot: a reaction's steps move the drawn
		# body while the walker's own place stays put.
		var at := w.pos + w.vis_off
		var state := str(w.react) if not w.react.is_empty() else w.state
		if react.call("fighting", w):
			state = "fight:%s" % state
		bits.append(
			"%s:%s@%.1fm" % [TEMPER_NAMES[react.call("temper_of", w)], state, at.length() / WS.M]
		)
	for w: WK.Walker in bystanders:
		bits.append("by:%s@%.1fm" % [str(w.react), w.pos.length() / WS.M])
	bits.append("landed:%d" % int(react.get("punches_landed")))
	print("BRAWL_WATCH: %.1fs %s" % [_t, "  ".join(bits)])
