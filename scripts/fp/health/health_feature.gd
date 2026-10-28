extends FpFeature
## The hero's health (integration slice; docs/fp/ARCHITECTURE.md, Health): MAX_HP points, shown
## as an arc round the left of the minimap. Crashes in the car the hero drives (car_impact), hard
## landings (the player's landed signal; one rolled off counts softer), people who fight back
## (hero_hit "punch", the fight_back flag), dogs defending their owners (hero_hit "bite", the
## animals feature) and cars that cannot stop for the hero on foot (hero_hit "car", hit_by_cars)
## cost points, and REGEN_DELAY seconds after the last hurt they come back. A blow makes the body
## flinch the way it came from, the camera rolling toward the side that was hit (hero_flinch; a
## guard raised toward it takes most of a punch), and in first person a short red arc flashes on
## the screen's edge toward where it came from (hit_direction); a car or a bad fall knocks the hero
## down, to lie a moment and get up. With nothing left they are knocked out: out of the car, down,
## the screen fades to black and they come round outside the nearest hospital (City Hall without
## one), healed. Every hurt goes out on the bus (hero_hurt); health is saved with the city.

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
## A punch or a bite costs PUNCH + PUNCH_K times its strength; the guard up toward a punch takes
## GUARD_K of that (a dog goes for the legs, under it).
const PUNCH := 5.0
const PUNCH_K := 10.0
const GUARD_K := 0.3
## The guard's poise (guard_chip): a punch the guard catches drains it by POISE_HIT + POISE_K
## times the blow's strength; once no guarded blow has landed for POISE_DELAY it knits back at
## POISE_REGEN a second. At none left the guard breaks: that blow lands in full, the guard drops
## and the hero staggers BREAK_S — input held, the view dipped (BREAK_KICK, pitch and roll off
## the side the blow came from).
const POISE_HIT := 0.2
const POISE_K := 0.3
const POISE_REGEN := 0.3
const POISE_DELAY := 0.8
const BREAK_S := 0.8
const BREAK_KICK := Vector2(-0.12, 0.05)
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
## A flinch's nudge grows across a blow's strength from this share of KICK to this much of it
## (hero_flinch, with hit_feel on; one size with it off), and a blow this far from the front
## (the cosine) reads as a head snap, anything else a fold of the chest.
const FLINCH_SCALE := Vector2(0.7, 1.5)
const FLINCH_FRONT := 0.25

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
## The clip the last flinch played (a test hook).
var flinch_clip: String = ""
## The guard's poise, 1 full (guard_chip; the arc shows it while short of full).
var poise: float = 1.0
## Seconds since a guarded blow last drained the poise, and the stagger left after a break.
var _poise_since: float = INF
var _break_t: float = -1.0
## The hero had input when the guard broke (given back as the stagger ends).
var _break_took: bool = false
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


## Takes amount of health for cause ("punch", "bite", "car", "crash", "fall"): the body flinches,
## or with knock it goes down and slides on along push (xz, u/s); with nothing left the hero is
## knocked out. felt (0..1) is how hard the blow reads on the flinch (derived from amount when
## left). bus.hero_hurt hears of it. Nothing while knocked out.
func hurt(
	amount: float,
	cause: String,
	push: Vector3 = Vector3.ZERO,
	knock: bool = false,
	felt: float = -1.0
) -> void:
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
		_flinch_body(push, felt if felt >= 0.0 else clampf(amount / (MAX_HP * 0.25), 0.0, 1.0))
	if _screen != null:
		_screen.call("flash", amount / MAX_HP)
	_flash_from(push)
	if ctx.bus != null:
		ctx.bus.hero_hurt.emit(amount, cause, hp, down)


## First person only (hit_direction): the screen-edge arc toward where the blow came from, beside
## the vignette's flash (health_screen's flash_from), and the hurt's thump panning the same way
## (hero_hit_dir, just before hero_hurt; the audio feature reads it). push points the way the
## blow travelled; the marker shows its source — angle 0 dead ahead, +PI/2 from the right. No
## push, no marker.
func _flash_from(push: Vector3) -> void:
	var p := ctx.player
	if p == null or p.camera_mode != "first" or not FeatureFlags.enabled("hit_direction"):
		return
	var src := Vector2(-push.x, -push.z)
	if src.length_squared() < 1e-10:
		return
	src = src.normalized()
	# The body's right is (cos, -sin) and it faces (-sin, -cos) (see _flinch_body).
	var side := src.dot(Vector2(cos(p.yaw), -sin(p.yaw)))
	var front := src.dot(Vector2(-sin(p.yaw), -cos(p.yaw)))
	var ang := atan2(side, front)
	if ctx.bus != null:
		ctx.bus.hero_hit_dir.emit(ang)
	if _screen != null:
		_screen.call("flash_from", ang)


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
	_poise_since += dt
	if out:
		_ko_step(dt)
	elif _down_t >= 0.0:
		_down_t -= dt
		if _down_t < 0.0:
			_stand()
	elif hp < MAX_HP and _since >= REGEN_DELAY:
		hp = minf(MAX_HP, hp + REGEN_RATE * dt)
	if poise < 1.0 and _poise_since >= POISE_DELAY:
		poise = minf(1.0, poise + POISE_REGEN * dt)
	if _break_t >= 0.0:
		_break_t -= dt
		if _break_t < 0.0:
			if _down_t >= 0.0 or out:
				# The knock-down's timer owns the input now; it gives the break's back too.
				_took_input = _took_input or _break_took
			else:
				var p := ctx.player
				if p != null:
					p.input_enabled = _break_took
					p.autopilot = {}
			_break_took = false
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
		_arc.call(
			"set_health", hp / MAX_HP, dt, poise if FeatureFlags.enabled("guard_chip") else -1.0
		)
	if _screen != null:
		var p := ctx.player
		var lost := 0.0 if p != null and p.photo_mode else 1.0 - hp / MAX_HP
		_screen.call("set_state", lost, _black(), _words(), dt)


func _flinch_body(push: Vector3, strength: float = 0.5) -> void:
	var p := ctx.player
	if p == null:
		return
	# The head rolls with the blow (the body's right is (cos, -sin)).
	var right := Vector2(cos(p.yaw), -sin(p.yaw))
	if not FeatureFlags.enabled("hero_flinch"):
		var side := 1.0 if Vector2(push.x, push.z).dot(right) >= 0.0 else -1.0
		p.kick_view(KICK.x, KICK.y * side)
		var plain := _rig()
		if plain != null and not p.carried and not bool(plain.call("action_active")):
			_flinch = (_flinch + 1) % FLINCHES.size()
			_rig_play(plain, FLINCHES[_flinch])
		return
	var flat := Vector2(push.x, push.z)
	var n := flat / flat.length() if flat.length_squared() > 1e-10 else Vector2.ZERO
	# sidef: shoved toward our right; front: the blow came at our face (the body faces
	# (-sin, -cos), so the push of one in the face points along (sin, cos)).
	var sidef := n.dot(right)
	var front := n.dot(Vector2(sin(p.yaw), cos(p.yaw)))
	var scale := 1.0
	if FeatureFlags.enabled("hit_feel"):
		scale = lerpf(FLINCH_SCALE.x, FLINCH_SCALE.y, clampf(strength, 0.0, 1.0))
	p.kick_view(KICK.x * scale, KICK.y * sidef * scale)
	var rig := _rig()
	# A body a move carries (a landing roll) only feels it in the view.
	if rig != null and not p.carried and not bool(rig.call("action_active")):
		_rig_play(rig, "hit_head" if front > FLINCH_FRONT else "hit_chest")


## Play the flinch clip on the rig (flinch_clip is the test hook).
func _rig_play(rig: RefCounted, clip: String) -> void:
	flinch_clip = clip
	rig.call("play_action", clip)


## True while the hero is down on the ground (knocked down or out): traffic reads it so the
## fight's reactions can answer a fall (downed_awareness).
func downed() -> bool:
	return out or _down_t >= 0.0


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
	poise = 1.0
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
	poise = 1.0
	_poise_since = INF
	_break_t = -1.0
	_break_took = false


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
		hurt(CAR_K * s, "car", push, s >= CAR_DOWN, s)
		return
	var k := GUARD_K if cause == "punch" and _guarded(at) else 1.0
	if k < 1.0 and FeatureFlags.enabled("guard_chip"):
		var was := poise
		poise = maxf(0.0, poise - (POISE_HIT + POISE_K * s))
		_poise_since = 0.0
		if poise <= 0.0:
			# A beaten guard catches nothing until the poise knits back.
			k = 1.0
			if was > 0.0:
				_guard_break(push)
	hurt((PUNCH + PUNCH_K * s) * k, cause, push * k, false, s)


## The guard breaks (guard_chip): it drops and the hero staggers BREAK_S — input held, the view
## dipped off the side the blow came from.
func _guard_break(push: Vector3) -> void:
	var actions := ctx.feature("actions")
	if actions != null and bool(actions.get("guarding")):
		actions.call("set_guard", false)
	var p := ctx.player
	if p != null:
		if _break_t < 0.0:
			_break_took = p.input_enabled
		_break_t = BREAK_S
		p.input_enabled = false
		p.autopilot = {"wish": Vector2.ZERO}
		var right := Vector2(cos(p.yaw), -sin(p.yaw))
		var side := 1.0 if Vector2(push.x, push.z).dot(right) >= 0.0 else -1.0
		p.kick_view(BREAK_KICK.x, BREAK_KICK.y * side)


## True when the guard is up (the actions feature) and at lies ahead of the hero.
func _guarded(at: Vector3) -> bool:
	var actions := ctx.feature("actions")
	var p := ctx.player
	if actions == null or p == null or not bool(actions.get("guarding")):
		return false
	var d := at - p.position
	return Vector2(d.x, d.z).dot(Vector2(p.body_forward().x, p.body_forward().z)) > 0.0
