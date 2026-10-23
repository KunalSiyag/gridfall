extends FpFeature
## Body actions (integration slice; docs/fp/ARCHITECTURE.md, Body actions): the hero's fists and
## gestures on foot. The strike button (left mouse, right trigger) throws a jab and a cross in
## turn, the body turning to whoever it goes for (else to where the camera looks); R shoves. The
## guard (right mouse or left trigger held: fists up, the body squared to where the camera looks,
## the camera in closer) is the fighting stance. A blow lands when the rig's fist is furthest out
## (HeroRig.strike_time) on the person nearest in front within REACH, through the traffic
## feature's hit_walker: they reel or go down, the people around react and the city hears of it.
## With nobody there it lands on the street prop in front (the props feature's strike): a bin,
## cone, wheelie bin or carton goes over, a fallen prop skids off. Keys 1-5 wave, nod, shake the
## head, shout and dance, and the people around answer (traffic answer_emote). The bus hears every
## swing and emote (hero_action).

const WS := preload("res://scripts/fp/world_scale.gd")

## Swings: [rig clip, hit_walker cause, strength 0..1, seconds until the next swing may start,
## seconds the clip plays, contact time (s) when the rig cannot measure it].
const SWINGS := {
	"jab": ["punch_jab", "punch", 0.45, 0.4, 0.55, 0.2],
	"cross": ["punch_cross", "punch", 0.6, 0.5, 0.65, 0.29],
	"shove": ["push", "shove", 0.35, 0.6, 0.55, 0.15],
}
## Emote input actions: [emote, seconds it plays (0 for the clip's own length)].
const EMOTES := {
	"emote_wave": ["wave", 0.0],
	"emote_yes": ["yes", 0.0],
	"emote_no": ["no", 2.0],
	"emote_shout": ["shout", 2.0],
	"emote_dance": ["dance", 8.0],
}
const INPUTS: Array[String] = [
	"act_strike",
	"act_shove",
	"act_aim",
	"emote_wave",
	"emote_yes",
	"emote_no",
	"emote_shout",
	"emote_dance",
]
## Who a swing can reach: on their feet within REACH (feet to feet) inside the cone ahead (the
## cosine); at contact still within REACH * HOLD_REACH.
const REACH := 1.2 * WS.M
const CONE := 0.4
const HOLD_REACH := 1.3
## Running adds up to this much strength (at WS.RUN).
const RUN_BONUS := 0.3
## A press this close to the end of a swing queues the next one (s); punches alternate jab and
## cross within COMBO_S of the last.
const BUFFER_S := 0.2
const COMBO_S := 1.0
const EMOTE_GAP := 1.0
## The body faces whoever a swing went for at least this long (s).
const FACE_S := 0.35
## The view kick when a blow lands (pitch, roll; radians) and the camera arm while the guard is
## up (TpsRig.arm_scale).
const KICK := Vector2(-0.015, 0.025)
const GUARD_ARM := 0.8
## Photo tour: frames to wait for the tour's teleport, how far round the hero to look for someone
## to square up to, how far in front of them the hero stands, and how far to their left (so the
## camera over the right shoulder sees them past the hero).
const PHOTO_FRAMES := 8
const PHOTO_R := 30.0 * WS.M
const PHOTO_GAP := 0.85 * WS.M
const PHOTO_SIDE := 0.55 * WS.M

## The guard is up.
var guarding: bool = false
## The swing under way ("jab", "cross", "shove") or "".
var swing: String = ""
## hit_walker's info for the last blow that landed; swings, blows landed on people and blows
## landed on street props so far; how many people answered the last emote.
var last_hit: Dictionary = {}
var swings: int = 0
var hits: int = 0
var prop_hits: int = 0
var answered: int = 0
var _forced_guard: bool = false
var _driving: bool = false
## Input action -> its trigger is past the dead zone (_pressed).
var _pad_held: Dictionary = {}
var _t: float = 0.0
var _len: float = 0.0
var _hit_at: float = 0.0
var _landed: bool = true
var _target: int = -1
## The swing a press near the end of the last one queued ("punch", "shove") or "".
var _queued: String = ""
var _combo_t: float = INF
var _next_punch: String = "jab"
var _emote_gap: float = 0.0
var _face_t: float = 0.0
var _face_yaw: float = NAN


func feature_id() -> String:
	return "actions"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.bus != null:
		link_signal(ctx.bus.drive_changed, _on_drive_changed)


func on_world_rebuilt() -> void:
	cancel()


func from_dict(_d: Dictionary) -> void:
	cancel()


func teardown() -> void:
	cancel()
	unlink_signals()


func self_test() -> Dictionary:
	var missing: Array[String] = []
	for a: String in INPUTS:
		if not InputMap.has_action(a):
			missing.append(a)
	if not missing.is_empty():
		return {"ok": false, "detail": "missing inputs %s" % str(missing)}
	var detail := "%d swings, %d blows landed, %d on props" % [swings, hits, prop_hits]
	return {"ok": true, "detail": detail}


## Whether the hero may swing, guard or emote now: on foot and in control of the body (not in a
## parkour move or on a wall), nothing modal open, not talking, not in photo mode, the phone put
## away.
func can_act() -> bool:
	var p := ctx.player if ctx != null else null
	if p == null or _driving or p.photo_mode or p.view_override or p.in_conversation():
		return false
	if p.carried:
		return false
	if ctx.is_modal():
		return false
	var phone := ctx.feature("phone")
	return phone == null or not bool(phone.get("open"))


## Starts a swing: what "punch" throws the next punch of the combo (a jab, then a cross within
## COMBO_S of the last), "shove" a shove. A press near the end of a swing queues the next. False
## when none starts now.
func strike(what: String = "punch") -> bool:
	if not can_act() or (what != "punch" and what != "shove"):
		return false
	if not swing.is_empty():
		if _len - _t <= BUFFER_S:
			_queued = what
		return false
	var kind := what
	if what == "punch":
		kind = _next_punch if _combo_t < COMBO_S else "jab"
		_next_punch = "cross" if kind == "jab" else "jab"
		_combo_t = 0.0
	var s: Array = SWINGS[kind]
	swing = kind
	_t = 0.0
	_len = float(s[3])
	_hit_at = float(s[5])
	_landed = false
	var rig := _rig()
	if rig != null:
		rig.call("stop_action")
		rig.call("play_action", str(s[0]), float(s[4]))
		if kind != "shove":
			_hit_at = minf(float(rig.call("strike_time", str(s[0]))), _len)
	var feet := ctx.player.position
	var who := _find_target(_aim_dir())
	_target = int(who.get("id", -1))
	# The body turns to whoever the swing goes for, else to where the camera looks.
	_face_yaw = ctx.player.cam_yaw
	if not who.is_empty():
		var d: Vector3 = (who["pos"] as Vector3) - feet
		_face_yaw = atan2(-d.x, -d.z)
	_face_t = maxf(_len, FACE_S)
	swings += 1
	if ctx.bus != null:
		ctx.bus.hero_action.emit(kind, feet)
	return true


## Raises or drops the guard for scripted play (tests, the photo tour); held input does the same.
func set_guard(on: bool) -> void:
	_forced_guard = on


## Plays an emote ("wave", "yes", "no", "shout", "dance") and lets the people around answer it.
## False when the hero cannot act now, swings or guards, the last emote was just now, or the
## dance is asked for on the move.
func emote(e: String) -> bool:
	if not can_act() or not swing.is_empty() or guarding or _emote_gap > 0.0:
		return false
	var secs := -1.0
	for a: String in EMOTES:
		if str(EMOTES[a][0]) == e:
			secs = float(EMOTES[a][1])
	if secs < 0.0:
		return false
	var rig := _rig()
	var av := ctx.player.avatar
	if e == "wave":
		if av != null and av.has_method("play_gesture"):
			av.call("play_gesture", "wave")
	elif rig != null and not bool(rig.call("play_action", e, secs)):
		return false
	_emote_gap = EMOTE_GAP
	var feet := ctx.player.position
	var tr := ctx.feature("traffic")
	answered = int(tr.call("answer_emote", feet, _aim_dir(), e)) if tr != null else 0
	if ctx.bus != null:
		ctx.bus.hero_action.emit(e, feet)
	return true


## Ends the swing, the guard and any action on the rig, and gives the body and camera back.
func cancel() -> void:
	swing = ""
	_queued = ""
	_landed = true
	_target = -1
	_forced_guard = false
	_face_t = 0.0
	if guarding or _rig() != null:
		_set_guarding(false)
	var rig := _rig()
	if rig != null and bool(rig.call("action_active")):
		rig.call("stop_action")
	_hand_back()


func _process(delta: float) -> void:
	if ctx == null or ctx.player == null:
		return
	tick(minf(delta, 0.1))


## One step: held input (or set_guard) raises the guard, the swing lands its blow, and the body
## faces the target or the aim.
func tick(dt: float) -> void:
	var held := _input_live() and Input.is_action_pressed("act_aim")
	var want := (_forced_guard or held) and can_act()
	# Every frame: a teleport snaps the rig's guard down, and the body may change.
	_set_guarding(want)
	_advance(dt)
	_face(dt)


## The strike and emote presses come as events (S0 §7.2), taken while the hero can act; a press
## the hero cannot act on passes on to the rest of the game.
func _unhandled_input(event: InputEvent) -> void:
	if ctx == null or ctx.player == null:
		return
	var press := ""
	for a: String in INPUTS:
		if a != "act_aim" and _pressed(event, a):
			press = a
	if press.is_empty() or not _input_live() or not can_act():
		return
	if press == "act_strike":
		strike()
	elif press == "act_shove":
		strike("shove")
	else:
		emote(str(EMOTES[press][0]))
	if is_inside_tree():
		get_viewport().set_input_as_handled()


## Whether event presses action: a key or button going down (not an echo), or a trigger crossing
## its dead zone. Every motion event past the dead zone reads as pressed, so _pad_held keeps
## the trigger's state between events.
func _pressed(event: InputEvent, action: String) -> bool:
	if not event.is_action(action):
		return false
	var down := event.is_action_pressed(action)
	if event is InputEventJoypadMotion:
		var was := bool(_pad_held.get(action, false))
		_pad_held[action] = down
		return down and not was
	return down and not event.is_echo()


## Player input drives the actions while it is enabled and, in a window, the mouse is captured.
## The click that captures it reaches this feature before FpMode (children first) and throws no
## punch.
func _input_live() -> bool:
	var mouse := (
		DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	)
	return ctx.player.input_enabled and mouse


func _advance(dt: float) -> void:
	_combo_t += dt
	_emote_gap = maxf(0.0, _emote_gap - dt)
	if swing.is_empty():
		return
	if not can_act():
		cancel()
		return
	_t += dt
	if not _landed and _t >= _hit_at:
		_land()
	if _t >= _len:
		swing = ""
		if not _queued.is_empty():
			var next := _queued
			_queued = ""
			strike(next)


## The blow lands on the swing's target if they are still in reach and on their feet; a swing at
## nobody lands on the street prop in front, if there is one.
func _land() -> void:
	_landed = true
	if _target < 0:
		_strike_prop()
		return
	var tr := ctx.feature("traffic")
	if tr == null:
		return
	var feet := ctx.player.position
	var who := {}
	for w: Dictionary in tr.call("walkers_near", feet, REACH * HOLD_REACH):
		if int(w["id"]) == _target:
			who = w
	if who.is_empty() or bool(who["down"]):
		return
	var d: Vector3 = (who["pos"] as Vector3) - feet
	d.y = 0.0
	var cause := str(SWINGS[swing][1])
	var info: Dictionary = tr.call("hit_walker", _target, feet, d.normalized(), _strength(), cause)
	if info.is_empty():
		return
	last_hit = info
	hits += 1
	_kick_view()


## A swing at nobody: the street prop in front within REACH takes the blow (props' strike).
func _strike_prop() -> void:
	var props := ctx.feature("props")
	var feet := ctx.player.position
	if props != null and bool(props.call("strike", feet, _aim_dir(), REACH, CONE, _strength())):
		prop_hits += 1
		_kick_view()


## The swing's strength: its own, and up to RUN_BONUS more at a run.
func _strength() -> float:
	return float(SWINGS[swing][2]) + RUN_BONUS * clampf(ctx.player.speed() / WS.RUN, 0.0, 1.0)


## The view kicks as a blow lands, rolled away from the punching hand.
func _kick_view() -> void:
	var side := {"jab": 1.0, "cross": -1.0}.get(swing, 0.0) as float
	ctx.player.kick_view(KICK.x, KICK.y * side)


## Third person: the body squares up to the camera while guarding and faces whoever a swing went
## for; the camera closes in on the guard.
func _face(dt: float) -> void:
	var p := ctx.player
	_face_t = maxf(0.0, _face_t - dt)
	if _face_t > 0.0 and not is_nan(_face_yaw):
		p.aim_yaw = _face_yaw
	elif guarding:
		p.aim_yaw = p.cam_yaw
	else:
		p.aim_yaw = NAN
	if p.rig != null:
		p.rig.arm_scale = GUARD_ARM if guarding else 1.0


func _set_guarding(on: bool) -> void:
	guarding = on
	var rig := _rig()
	if rig != null:
		rig.call("set_guard", on)


func _hand_back() -> void:
	var p := ctx.player if ctx != null else null
	if p == null:
		return
	p.aim_yaw = NAN
	if p.rig != null:
		p.rig.arm_scale = 1.0


## The person on their feet nearest the hero within REACH inside the cone around dir (walkers_near's
## entry), {} for none.
func _find_target(dir: Vector3) -> Dictionary:
	var tr := ctx.feature("traffic")
	if tr == null:
		return {}
	var feet := ctx.player.position
	var best := {}
	var bd := INF
	for w: Dictionary in tr.call("walkers_near", feet, REACH):
		var d: Vector3 = (w["pos"] as Vector3) - feet
		d.y = 0.0
		var dist := d.length()
		var ahead := dist < 1e-5 or d.dot(dir) / dist >= CONE
		if ahead and not bool(w["down"]) and dist < bd:
			bd = dist
			best = w
	return best


## Where a swing looks for its target and an emote is aimed: along the camera, level.
func _aim_dir() -> Vector3:
	var y := ctx.player.cam_yaw
	return Vector3(-sin(y), 0.0, -cos(y))


## The hero's animated rig (HeroRig), or null for the placeholder body.
func _rig() -> RefCounted:
	var av := ctx.player.avatar if ctx != null and ctx.player != null else null
	if av == null or not av.has_method("is_animated") or not bool(av.call("is_animated")):
		return null
	var r: Variant = av.get("rig")
	if r is RefCounted and (r as RefCounted).has_method("play_action"):
		return r
	return null


func _on_drive_changed(active: bool) -> void:
	_driving = active
	if active:
		cancel()


# --- Photo tour


func photo_shots() -> Array:
	if ctx.feature("traffic") == null or ctx.mode == null:
		return []
	var sp: Dictionary = ctx.mode.spawn_point()
	var shot := {"name": "actions_guard", "pos": sp["pos"], "yaw": float(sp["yaw"]), "pitch": -6.0}
	shot.merge({"hour": 10.5, "prepare": "photo_prepare", "restore": "photo_restore"})
	return [shot]


## Third person; once the tour has put the hero down, it squares up to the nearest person, who
## reels from a blow.
func photo_prepare() -> void:
	ctx.mode.apply_settings({"camera_mode": "third"}, false)
	ctx.player.set_camera_mode("third", false)
	_photo_stage.call_deferred()


func photo_restore() -> void:
	cancel()
	ctx.mode.apply_settings({"camera_mode": "first"}, false)
	ctx.player.set_camera_mode("first", false)


func _photo_stage() -> void:
	for _k in range(PHOTO_FRAMES):
		await get_tree().process_frame
	var tr := ctx.feature("traffic")
	if tr == null:
		return
	var p := ctx.player
	var best := {}
	var bd := INF
	for w: Dictionary in tr.call("walkers_near", p.position, PHOTO_R):
		var dist := (w["pos"] as Vector3).distance_to(p.position)
		if not bool(w["down"]) and dist < bd:
			bd = dist
			best = w
	set_guard(true)
	if best.is_empty():
		return
	var wy := float(best["yaw"])
	var facing := Vector3(sin(wy), 0.0, cos(wy))
	# The hero faces them (its yaw wy looks along -facing), with them to its right.
	var right := Vector3(cos(wy), 0.0, -sin(wy))
	var at := (best["pos"] as Vector3) + facing * PHOTO_GAP - right * PHOTO_SIDE
	p.teleport(at, rad_to_deg(wy), -6.0)
	tr.call("pose_walker", int(best["id"]), &"hit_head", 0.2)
