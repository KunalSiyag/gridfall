extends RefCounted
## The drive feature's input (drive_feature.gd): F takes or leaves a car (a second press on the
## way to the door turns back), V toggles the chase and driver views, the mouse orbits the chase
## camera, and H sounds the horn (a bicycle's bell, the night_driving flag) at most once per
## HORN_GAP — a press leaned on past HORN_LONG_S carries long through the street (horn_sounded,
## the horn_street flag). The state the rest of the drive reads stays on the feature.

const WS := preload("res://scripts/fp/world_scale.gd")

## The horn (a bicycle's bell) sounds at most this often (s).
const HORN_GAP := 0.75
## How far the horn carries into the street (horn_sounded, the horn_street flag), and the hold
## that turns a press long.
const HORN_STREET_R := 35.0 * WS.M
const HORN_LONG_S := 0.6

## The drive feature this handles the keys for.
var _d: Object
## Seconds until the horn (a bicycle's bell) can sound again (the night_driving flag).
var _horn_t: float = 0.0
## The horn press being held down (the horn_street flag), or -1 with none.
var _horn_hold: float = -1.0
var _horn_long_done := false


func _init(drive: Object) -> void:
	_d = drive


## Clears the horn timers (a fresh claim: nothing held, nothing cooling down).
func reset() -> void:
	_horn_t = 0.0
	_horn_hold = -1.0
	_horn_long_done = false


## Per drive step: the horn's cooldown, and a press still down past HORN_LONG_S turning long.
func step(dt: float) -> void:
	_horn_t -= dt
	if _horn_hold >= 0.0:
		_horn_hold = _horn_hold + dt if Input.is_action_pressed("vehicle_horn") else -1.0
		if _horn_hold >= HORN_LONG_S and not _horn_long_done:
			_horn_long_done = true
			# A held press sounds long too (the class_audio flag), not only in the street.
			if FeatureFlags.enabled("class_audio") and not _d.bike and _d.ctx.bus != null:
				_d.ctx.bus.hero_action.emit(
					_horn_action(true), _d._pos + Vector3(0.0, _d._dims.y * 0.5, 0.0)
				)
			_horn_street(true)


## The feature's _input: F at any time, the rest while driving (not climbing in or out).
func input(event: InputEvent) -> void:
	var ctx: FpContext = _d.ctx
	if ctx == null or ctx.player == null or ctx.is_modal() or event.is_echo():
		return
	var handled := false
	var driving: bool = _d.active and not _d._climbing()
	if event.is_action_pressed("vehicle_enter"):
		handled = _enter_key()
	elif driving and event.is_action_pressed("view_toggle"):
		_d.view = "driver" if _d.view == "chase" else "chase"
		handled = true
	elif driving and event.is_action_pressed("vehicle_horn"):
		# The horn, or a bicycle's bell (the night_driving flag). The press is only taken with
		# the flag on, so H keeps its other meaning with it off (the actions feature leaves it
		# be while driving either way).
		if FeatureFlags.enabled("night_driving"):
			horn()
			handled = true
	elif (
		driving and event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	):
		var rel := (event as InputEventMouseMotion).relative
		var sens := float(ctx.settings.get("mouse_sensitivity", WS.MOUSE_SENSITIVITY))
		_d._orbit_by(-rel.x * sens, rel.y * sens)
		handled = true
	if handled and _d.is_inside_tree():
		_d.get_viewport().set_input_as_handled()


## The horn, or a bicycle's bell (the night_driving flag): one press sounds it at the car on
## hero_action, at most once per HORN_GAP seconds, and carries through the street (horn_sounded).
func horn() -> void:
	if _horn_t > 0.0:
		return
	_horn_t = HORN_GAP
	_horn_hold = 0.0
	_horn_long_done = false
	if _d.ctx.bus != null:
		_d.ctx.bus.hero_action.emit(
			_horn_action(false), _d._pos + Vector3(0.0, _d._dims.y * 0.5, 0.0)
		)
		_horn_street(false)


## The vehicle_enter key (F, pad Y): driving or climbing, the key is always taken (a refusal
## toasts why); on foot only with a car near. On the way to the door it turns back. Returns
## whether the drive feature took it.
func _enter_key() -> bool:
	if _d._climbing():
		if _d.entry.kind == "in" and not _d.entry.aboard():
			_d.exit()
		return true
	if _d.active:
		if not _d.jump_across():
			_d.leave()
		return true
	return _d.board()


## The hero_action word for this ride's horn (the class_audio flag): a bicycle's bell, the
## scooter's or a lorry's own voice, and a held press's long lean. Without the flag every horn
## is the car's, as before.
func _horn_action(long: bool) -> String:
	if _d.bike:
		return "bell"
	if not FeatureFlags.enabled("class_audio"):
		return "horn"
	var a := "horn"
	if _d.scooter:
		a = "horn_scooter"
	elif _d.kind in ["truck", "bus", "emergency"]:
		a = "horn_truck"
	return (a + "_long") if long else a


## Puts the horn on the bus for the street round it (the horn_street flag): a tap short, a press
## leaned on long; a bicycle's bell carries nothing.
func _horn_street(long: bool) -> void:
	if _d.bike or not FeatureFlags.enabled("horn_street") or _d.ctx.bus == null:
		return
	var at: Vector3 = _d._pos + Vector3(0.0, _d._dims.y * 0.5, 0.0)
	_d.ctx.bus.horn_sounded.emit(Vector2(at.x, at.z), HORN_STREET_R, long)
