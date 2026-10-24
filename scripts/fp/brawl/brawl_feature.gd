extends FpFeature
## Close combat (integration feature "brawl"; docs/fp/ARCHITECTURE.md, Brawl): grapples and the
## counter cue. H (or the back mouse button) takes hold of the person on their feet in front
## within GRAB_REACH: they hang in the hero's hands HOLD_GAP ahead, the hero's fists up and the body
## squared to the camera, dragged along at DRAG_SPEED at most. Punches land on them where they hang
## (the combo's hook or the third in a row puts them down), R throws them where the camera looks
## (the actions feature's "throw": knocked down and flung) and H again lets go; after a while they
## break free (traffic's reactions.gd holds them). The hold ends when the hero can no longer act
## (driving, knocked down, a modal open). Someone fighting the hero who starts a punch flashes the
## counter cue under the crosshair (hero_threatened) until it lands: the guard raised in time
## counters it (the actions feature's parry, the counters flag).

const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const INPUTS: Array[String] = ["act_grab"]
## Who can be grabbed: on their feet within GRAB_REACH (feet to feet) inside the cone ahead of the
## camera (the cosine).
const GRAB_REACH := 1.1 * WS.M
const GRAB_CONE := 0.5
## Where the held person's feet go: HOLD_GAP ahead of the hero's.
const HOLD_GAP := 0.6 * WS.M
## The hero's top speed dragging someone (u/s).
const DRAG_SPEED := 1.1 * WS.M
## The reach for them as the hold starts (the rig's push clip, seconds).
const REACH_S := 0.3
## The counter cue stays this long past the punch's landing (s).
const CUE_TAIL := 0.15

## The walkers_near id of the person held, -1 for none; holds taken so far.
var held_id: int = -1
var grabs: int = 0
## The counter cue, and how long it stays.
var cue: Label
var cue_t: float = 0.0


func feature_id() -> String:
	return "brawl"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.bus != null:
		link_signal(ctx.bus.hero_threatened, _on_threatened)
		link_signal(ctx.bus.drive_changed, _on_drive_changed)
	if ctx.hud != null:
		cue = S.label("!", 34, S.RED)
		cue.name = "CounterCue"
		cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cue.anchor_left = 0.5
		cue.anchor_right = 0.5
		cue.anchor_top = 0.5
		cue.anchor_bottom = 0.5
		cue.offset_left = -20.0
		cue.offset_right = 20.0
		cue.offset_top = 28.0
		cue.offset_bottom = 72.0
		cue.visible = false
		ctx.hud.slot("center").add_child(cue)


func on_world_rebuilt() -> void:
	release()


func from_dict(_d: Dictionary) -> void:
	release()


func teardown() -> void:
	release()
	unlink_signals()
	if cue != null and is_instance_valid(cue):
		cue.queue_free()
	cue = null


func self_test() -> Dictionary:
	for a: String in INPUTS:
		if not InputMap.has_action(a):
			return {"ok": false, "detail": "missing input %s" % a}
	return {"ok": true, "detail": "%d grabs" % grabs}


## Takes hold of the person on their feet in front (on foot, upright, free to act). False when
## nobody is there or the hero cannot now.
func grab() -> bool:
	var tr := ctx.feature("traffic") if ctx != null else null
	if held_id >= 0 or tr == null or not _free():
		return false
	var p := ctx.player
	if p.crouched or not p.grounded:
		return false
	var who := _target(tr)
	if who.is_empty() or not bool(tr.call("grab_walker", int(who["id"]), p.position)):
		return false
	held_id = int(who["id"])
	grabs += 1
	p.speed_cap = DRAG_SPEED
	var rig: Variant = p.avatar.get("rig") if p.avatar != null else null
	if rig is RefCounted and (rig as RefCounted).has_method("play_action"):
		rig.call("play_action", "push", REACH_S)
	if ctx.bus != null:
		ctx.bus.hero_action.emit("grapple", p.position)
	return true


## Lets go of whoever is held.
func release() -> void:
	if held_id < 0:
		return
	var tr := ctx.feature("traffic") if ctx != null else null
	if tr != null:
		tr.call("release_walker", held_id)
	_end()


## True while someone is held.
func holding() -> bool:
	return held_id >= 0


func _process(delta: float) -> void:
	if ctx == null or ctx.player == null:
		return
	tick(minf(delta, 0.1))


## One step: the cue fades, and the person held goes where the hero's hands are (or the hold ends).
func tick(dt: float) -> void:
	cue_t = maxf(0.0, cue_t - dt)
	if cue != null:
		cue.visible = cue_t > 0.0 and not ctx.player.photo_mode
	if held_id < 0:
		return
	var tr := ctx.feature("traffic")
	if tr == null or not _free(true):
		release()
		return
	var p := ctx.player
	var f := p.body_forward()
	var at := p.position + Vector3(f.x, 0.0, f.z).normalized() * HOLD_GAP
	if not bool(tr.call("hold_walker", held_id, at, atan2(-f.x, -f.z))):
		_end()


func _end() -> void:
	held_id = -1
	if ctx != null and ctx.player != null:
		ctx.player.speed_cap = INF


## True when the hero may grab (or, holding, go on holding): in control, and the actions feature
## lets them act with no swing under way (one may be under way while holding).
func _free(holding_now: bool = false) -> bool:
	var a := ctx.feature("actions")
	var p := ctx.player
	if a == null or p == null or not p.input_enabled or not bool(a.call("can_act")):
		return false
	return holding_now or str(a.get("swing")).is_empty()


## The nearest person on their feet within GRAB_REACH in the cone ahead of the camera, {} for none.
func _target(tr: Node) -> Dictionary:
	var p := ctx.player
	var aim := Vector2(-sin(p.cam_yaw), -cos(p.cam_yaw))
	var best := {}
	var bd := INF
	for w: Dictionary in tr.call("walkers_near", p.position, GRAB_REACH):
		var q: Vector3 = w["pos"]
		var d := Vector2(q.x - p.position.x, q.z - p.position.z)
		var dist := d.length()
		if bool(w["down"]) or (dist > 1e-5 and d.dot(aim) < GRAB_CONE * dist):
			continue
		if dist < bd:
			bd = dist
			best = w
	return best


func _unhandled_input(event: InputEvent) -> void:
	if ctx == null or ctx.player == null or not event.is_action_pressed("act_grab"):
		return
	if event.is_echo() or not ctx.player.input_enabled:
		return
	var live := (
		DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	)
	if not live:
		return
	if held_id >= 0:
		release()
	elif not grab():
		return
	if is_inside_tree():
		get_viewport().set_input_as_handled()


## A punch at the hero lands in secs: the cue shows until just after (the counters flag).
func _on_threatened(_at: Vector3, secs: float) -> void:
	if FeatureFlags.enabled("counters"):
		cue_t = maxf(cue_t, secs + CUE_TAIL)


func _on_drive_changed(active: bool) -> void:
	if active:
		release()
