extends FpFeature
## The hero's health (integration slice; docs/fp/ARCHITECTURE.md, Health): MAX_HP points, shown
## as an arc round the left of the minimap. Crashes in the car the hero drives (car_impact), hard
## landings (the player's landed signal; one rolled off counts softer), people who fight back
## (hero_hit "punch", the fight_back flag) and cars that cannot stop for the hero on foot
## (hero_hit "car", hit_by_cars) cost points, and REGEN_DELAY seconds after the last hurt they
## come back. A blow makes the body flinch (a guard raised toward it takes most of a punch); a car
## or a bad fall knocks the hero down, to lie a moment and get up. With nothing left they are
## knocked out: out of the car, down, the screen fades to black and they come round outside the
## nearest hospital (City Hall without one), healed. Every hurt goes out on the bus (hero_hurt);
## health is saved with the city.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const ARC := preload("res://scripts/fp/health/health_arc.gd")
const SCREEN := preload("res://scripts/fp/health/health_screen.gd")

const MAX_HP := 100.0
## Health comes back REGEN_RATE points a second once REGEN_DELAY seconds have passed since the
## last hurt.
const REGEN_DELAY := 6.0
const REGEN_RATE := 5.0
## A crash's closing speed (m/s) up to CRASH_SAFE costs nothing; CRASH_KO would empty a full bar
## (a head-on at top speed leaves little).
const CRASH_SAFE := 7.0
const CRASH_KO := 32.0
## Landing faster than FALL_SAFE (m/s down; about a 1.8 m drop) hurts and FALL_KO (a 10 m drop)
## would empty a full bar; a landing that costs FALL_DOWN or more knocks the hero down.
const FALL_SAFE := 6.0
const FALL_KO := 14.0
const FALL_DOWN := 35.0
## A landing rolled off (the parkour feature's landing roll) counts ROLL_SAVE m/s slower and does
## not knock the hero down.
const ROLL_SAVE := 4.0
## A punch costs PUNCH + PUNCH_K times its strength; the guard up toward it takes GUARD_K of that.
const PUNCH := 5.0
const PUNCH_K := 10.0
const GUARD_K := 0.3
## A car's blow costs CAR_K times its strength (0..1) and from CAR_DOWN on knocks the hero down.
const CAR_K := 100.0
const CAR_DOWN := 0.25
## Knocked down: the body falls (the rig's knockback), lies LIE_S seconds and gets up (its get_up;
## GET_UP s without the rig). The push throws the body on along the ground, slowing at SLIDE_DECEL
## (u/s²; a tumble on the road), so a car at v throws the hero v² / (2 SLIDE_DECEL) on: further
## than it takes to stop at full braking.
const LIE_S := 1.4
const GET_UP := 1.6
const SLIDE_DECEL := 7.0 * WS.M
## Knocked out: the fade to black (s), the black (the hero is moved half way through) and the
## fade back in.
const KO_FADE := 2.2
const KO_HOLD := 1.0
const KO_IN := 1.4
## The view kick (pitch, roll; radians) of a flinch and of a knock-down.
const KICK := Vector2(-0.03, 0.04)
const KICK_DOWN := Vector2(0.3, 0.12)
const FLINCHES: Array[String] = ["hit_head", "hit_chest"]

## Health points, 0..MAX_HP.
var hp: float = MAX_HP
## Knocked out: from the fall until the hero comes round.
var out: bool = false
## Hurts and knock-outs so far, and where the hero came round last (the hospital's name, "" at
## City Hall).
var hurts: int = 0
var knockouts: int = 0
var woke_at: String = ""
var _since: float = INF
## Seconds left on the ground (and getting up) while knocked down; < 0 when standing.
var _down_t: float = -1.0
## Seconds since the knock-out while out; < 0 otherwise.
var _ko_t: float = -1.0
var _woke: bool = false
## The hero had input when knocked down (it is given back on getting up).
var _took_input: bool = false
var _push := Vector3.ZERO
var _flinch: int = 0
var _player_linked: bool = false
var _arc: Control
var _screen: Control


func feature_id() -> String:
	return "health"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.bus != null:
		link_signal(ctx.bus.car_impact, _on_car_impact)
		link_signal(ctx.bus.hero_hit, _on_hero_hit)
	_link_player()
	if ctx.hud != null:
		_arc = ARC.new()
		ctx.hud.slot("minimap_slot").add_child(_arc)
		_arc.call("setup")
		_screen = SCREEN.new()
		var overlay := ctx.hud.slot("overlay")
		overlay.add_child(_screen)
		# Under the pause menu and the map.
		overlay.move_child(_screen, 0)
		_screen.call("setup")
	_show(0.0)


func on_world_rebuilt() -> void:
	_link_player()
	_reset()


func to_dict() -> Dictionary:
	return {"hp": snappedf(hp, 0.1)}


func from_dict(d: Dictionary) -> void:
	_reset()
	hp = clampf(float(d.get("hp", MAX_HP)), 1.0, MAX_HP)
	_since = INF
	_show(0.0)


func teardown() -> void:
	_reset()
	unlink_signals()
	for n: Control in [_arc, _screen]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_arc = null
	_screen = null


func self_test() -> Dictionary:
	var ok := hp >= 0.0 and hp <= MAX_HP and (ctx.hud == null or _arc != null)
	return {"ok": ok, "detail": "%d hp, %d hurts, %d knock-outs" % [roundi(hp), hurts, knockouts]}


## Takes amount of health for cause ("punch", "car", "crash", "fall"): the body flinches, or with
## knock it goes down and slides on along push (xz, u/s); with nothing left the hero is knocked
## out. bus.hero_hurt hears of it. Nothing while knocked out.
func hurt(amount: float, cause: String, push: Vector3 = Vector3.ZERO, knock: bool = false) -> void:
	if out or not (amount > 0.0) or ctx == null:
		return
	hp = maxf(0.0, hp - amount)
	_since = 0.0
	hurts += 1
	var down := knock or hp <= 0.0
	if hp <= 0.0:
		_knock_out(push)
	elif knock:
		_knock_down(push, LIE_S)
	else:
		_flinch_body(push)
	if _screen != null:
		_screen.call("flash", amount / MAX_HP)
	if ctx.bus != null:
		ctx.bus.hero_hurt.emit(amount, cause, hp, down)


## True while the hero is on the ground (knocked down or out) or coming round.
func knocked() -> bool:
	return out or _down_t >= 0.0


func _process(delta: float) -> void:
	if ctx != null:
		tick(minf(delta, 0.1))


## One step: health comes back, a knock-down runs out and the hero gets up, a knock-out runs its
## fade and moves the hero; the slide and the HUD follow.
func tick(dt: float) -> void:
	_since += dt
	if out:
		_ko_step(dt)
	elif _down_t >= 0.0:
		_down_t -= dt
		if _down_t < 0.0:
			_stand()
	elif hp < MAX_HP and _since >= REGEN_DELAY:
		hp = minf(MAX_HP, hp + REGEN_RATE * dt)
	_slide(dt)
	_show(dt)


func _ko_step(dt: float) -> void:
	_ko_t += dt
	if not _woke and _ko_t >= KO_FADE + KO_HOLD * 0.5:
		_wake()
	if _ko_t >= KO_FADE + KO_HOLD + KO_IN:
		out = false
		_ko_t = -1.0
		_stand()
		_toast_wake()


## How black the screen is (0..1) through a knock-out.
func _black() -> float:
	if _ko_t < 0.0:
		return 0.0
	if _ko_t < KO_FADE:
		return _ko_t / KO_FADE
	return clampf(1.0 - (_ko_t - KO_FADE - KO_HOLD) / KO_IN, 0.0, 1.0)


## The knock-out's caption (0..1): it comes up as the screen goes dark, until the hero is moved.
func _words() -> float:
	if not out or _woke:
		return 0.0
	return clampf(_ko_t / KO_FADE * 2.0 - 1.0, 0.0, 1.0)


func _show(dt: float) -> void:
	if _arc != null:
		_arc.call("set_health", hp / MAX_HP, dt)
	if _screen != null:
		var p := ctx.player
		var lost := 0.0 if p != null and p.photo_mode else 1.0 - hp / MAX_HP
		_screen.call("set_state", lost, _black(), _words(), dt)


func _flinch_body(push: Vector3) -> void:
	var p := ctx.player
	if p == null:
		return
	# The head rolls with the blow (the body's right is (cos, -sin)).
	var right := Vector2(cos(p.yaw), -sin(p.yaw))
	var side := 1.0 if Vector2(push.x, push.z).dot(right) >= 0.0 else -1.0
	p.kick_view(KICK.x, KICK.y * side)
	var rig := _rig()
	# A body a move carries (a landing roll) only feels it in the view.
	if rig != null and not p.carried and not bool(rig.call("action_active")):
		_flinch = (_flinch + 1) % FLINCHES.size()
		rig.call("play_action", FLINCHES[_flinch])


## Down on the ground for lie seconds, then up again: input is held (given back on getting up),
## the actions stop, the body turns to face where the blow came from and slides on along push.
func _knock_down(push: Vector3, lie: float) -> void:
	var p := ctx.player
	if p == null:
		return
	if _down_t < 0.0:
		_took_input = p.input_enabled
	p.input_enabled = false
	# Gravity and the walk spring keep running with no input.
	p.autopilot = {"wish": Vector2.ZERO}
	var actions := ctx.feature("actions")
	if actions != null:
		actions.call("cancel")
	var flat := Vector2(push.x, push.z)
	if flat.length_squared() > 1e-12:
		p.yaw = atan2(push.x, push.z)
		p.rotation.y = p.yaw
	_push = Vector3(push.x, 0.0, push.z)
	p.kick_view(KICK_DOWN.x, KICK_DOWN.y)
	_down_t = lie + GET_UP
	var rig := _rig()
	if rig != null:
		rig.call("play_action", "knockdown", lie)
		var lens: Dictionary = rig.get("lengths")
		_down_t = float(lens.get("knockback", 0.0)) + lie + float(lens.get("get_up", GET_UP))


## Knocked out: out of the car the hero drives, down until the screen is black.
func _knock_out(push: Vector3) -> void:
	out = true
	knockouts += 1
	_ko_t = 0.0
	_woke = false
	var drive := ctx.feature("drive")
	if drive != null:
		# On foot beside the car (input back), so the knock-down takes the input as usual.
		drive.call("exit", true)
	_knock_down(push, KO_FADE + KO_HOLD)


## Up again: input back if the knock-down took it.
func _stand() -> void:
	_down_t = -1.0
	_push = Vector3.ZERO
	var p := ctx.player
	if p == null:
		return
	p.autopilot = {}
	if _took_input:
		p.input_enabled = true
	_took_input = false


## In the dark: the hero comes round outside the nearest hospital, healed.
func _wake() -> void:
	_woke = true
	hp = MAX_HP
	_since = INF
	_push = Vector3.ZERO
	var spot := hospital_spot(ctx.player_position())
	woke_at = str(spot["name"])
	var p := ctx.player
	if p == null:
		return
	p.teleport(spot["pos"], float(spot["yaw"]))
	if ctx.mode != null:
		ctx.mode.unstick_player()


func _toast_wake() -> void:
	if ctx.bus == null:
		return
	if woke_at.is_empty():
		ctx.bus.toast.emit("You came round outside City Hall. The city has no hospital.", "alert")
	else:
		ctx.bus.toast.emit("You came round outside %s." % woke_at, "alert")


## Where a hero knocked out near from comes round: the sidewalk outside the nearest hospital,
## facing the street ({"pos", "yaw" (deg), "name"}), else City Hall's spawn point (name "").
func hospital_spot(from: Vector3) -> Dictionary:
	var sim := ctx.sim
	var best := -1
	var road := -1
	var best_d := INF
	if sim != null and ctx.directory != null:
		for i in sim.active:
			if sim.kind[i] != D.HOSPITAL:
				continue
			var r := ctx.directory.frontage(i)
			var dd := Vector2(D.tx(i) - from.x, D.ty(i) - from.z).length_squared()
			if r >= 0 and dd < best_d:
				best_d = dd
				best = i
				road = r
	if best < 0:
		var sp: Dictionary = (
			ctx.mode.spawn_point() if ctx.mode != null else {"pos": from, "yaw": 0.0}
		)
		return {"pos": sp["pos"], "yaw": float(sp["yaw"]), "name": ""}
	var dir := Vector3(D.tx(best) - D.tx(road), 0.0, D.ty(best) - D.ty(road))
	var pos := Vector3(D.tx(road), 0.0, D.ty(road)) + dir * WS.SIDEWALK_CENTER
	var g := ctx.collision.ground_height(pos) if ctx.collision != null else NAN
	pos.y = g if not is_nan(g) else 0.0
	var label := ctx.directory.landmark_name(best)
	return {
		"pos": pos,
		"yaw": rad_to_deg(atan2(dir.x, dir.z)),
		"name": label if not label.is_empty() else "the hospital",
	}


## The push throws the body on along the ground, slowing (stopped by walls and posts).
func _slide(dt: float) -> void:
	var p := ctx.player
	var sp := _push.length()
	if p == null or sp < 1e-6:
		return
	var mv := _push * dt
	_push *= maxf(0.0, sp - SLIDE_DECEL * dt) / sp
	if ctx.collision != null:
		var h := WS.PLAYER_HEIGHT
		p.position = ctx.collision.move_body(p.position, mv, WS.PLAYER_RADIUS, h, WS.STEP_HEIGHT)
	else:
		p.position += mv


## Back on the feet with input as it was, nothing pending (load, rebuild, teardown): a body on
## the ground stands at once.
func _reset() -> void:
	if _down_t >= 0.0 or out:
		_stand()
		var rig := _rig()
		if rig != null:
			rig.call("snap", false)
	out = false
	_ko_t = -1.0
	_down_t = -1.0
	_push = Vector3.ZERO


func _link_player() -> void:
	if _player_linked or ctx.player == null:
		return
	link_signal(ctx.player.landed, _on_landed)
	_player_linked = true


## The hero's animated rig while the body animates, else null.
func _rig() -> RefCounted:
	var av: Node3D = ctx.player.avatar if ctx.player != null else null
	if av == null or not bool(av.call("is_animated")):
		return null
	return av.get("rig") as RefCounted


func _on_car_impact(_at: Vector3, speed: float, _what: String) -> void:
	var v := speed / WS.M
	if v > CRASH_SAFE:
		hurt(MAX_HP * (v - CRASH_SAFE) / (CRASH_KO - CRASH_SAFE), "crash")


func _on_landed(speed_mps: float, rolled: bool = false) -> void:
	var v := speed_mps - (ROLL_SAVE if rolled else 0.0)
	if v <= FALL_SAFE:
		return
	var amount := MAX_HP * (v - FALL_SAFE) / (FALL_KO - FALL_SAFE)
	hurt(amount, "fall", Vector3.ZERO, amount >= FALL_DOWN and not rolled)


func _on_hero_hit(at: Vector3, cause: String, strength: float, push: Vector3) -> void:
	var s := clampf(strength, 0.0, 1.0)
	if cause == "car":
		hurt(CAR_K * s, "car", push, s >= CAR_DOWN)
		return
	var k := GUARD_K if _guarded(at) else 1.0
	hurt((PUNCH + PUNCH_K * s) * k, cause, push * k)


## True when the guard is up (the actions feature) and at lies ahead of the hero.
func _guarded(at: Vector3) -> bool:
	var actions := ctx.feature("actions")
	var p := ctx.player
	if actions == null or p == null or not bool(actions.get("guarding")):
		return false
	var d := at - p.position
	return Vector2(d.x, d.z).dot(Vector2(p.body_forward().x, p.body_forward().z)) > 0.0
