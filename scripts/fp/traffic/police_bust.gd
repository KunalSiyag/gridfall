extends RefCounted
## The hero taken by the police (police_response.gd, the police_response flag). A toast says what
## they were fined and for what ("Busted: fined $500 for carjacking": the game has no wallet for the
## hero, so the fine is the message and the street's relief, incidents.gd arrested()), the screen
## fades to black over FADE_OUT, the hero is put out of any car and outside the nearest police
## station (where they stand when the city has none) as it goes black, and the picture comes back
## over FADE_IN (with "Released outside <station>", on the screen once it can be seen), input held
## through all of it. hero_busted goes out on the bus for anyone listening. The fade runs on real
## seconds (tick, from the traffic feature's _process), not the sim's. The input is held by taking
## it again whenever something else hands it back during the fade (the health feature's stagger
## does at its end), and given back only if it was the arrest that took it: an arrest in the middle
## of someone else's hold leaves that hold's end to them.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FADE_OUT := 0.5
const HOLD := 0.3
const FADE_IN := 0.8
## What each offence (incidents.gd's cause; "officer" a blow at one) is called in the fine.
const FOR := {"carjack": "carjacking", "punch": "assault", "officer": "assaulting an officer"}

var f: Object
## Arrests so far, and the dollars fined (a test hook and a tally).
var busted: int = 0
var fined: int = 0
var _t: float = -1.0
var _moved: bool = false
var _released: String = ""
var _took_input: bool = false
var _layer: ColorRect = null


func setup(p_f: Object) -> void:
	f = p_f


## Drops the fade (a world rebuild or teardown) and gives the hero back their input.
func clear() -> void:
	if _t >= 0.0:
		_finish()
	if _layer != null and is_instance_valid(_layer):
		# Out of the tree at once: a queued free leaves its name taken for the rest of the frame.
		if _layer.get_parent() != null:
			_layer.get_parent().remove_child(_layer)
		_layer.queue_free()
	_layer = null


## The hero is busted at at (on street): fined fine for why. Nothing while an arrest is under way.
func begin(fine: int, why: String, at: Vector3, street: String) -> void:
	if _t >= 0.0:
		return
	busted += 1
	fined += fine
	_t = 0.0
	_moved = false
	_released = ""
	var p: Variant = f.ctx.player
	if p != null:
		_took_input = bool(p.input_enabled)
		p.input_enabled = false
	f.incidents.arrested(at, street)
	if f.ctx.bus != null:
		var text := "Busted: fined $%d" % fine
		if FOR.has(why):
			text += " for " + str(FOR[why])
		f.ctx.bus.toast.emit(text, "alert")
		f.ctx.bus.hero_busted.emit(fine, why, at)


## True from the arrest until the picture is back.
func active() -> bool:
	return _t >= 0.0


## One frame of the fade, delta real seconds.
func tick(delta: float) -> void:
	if _t < 0.0:
		return
	_t += delta
	_hold_input()
	if not _moved and _t >= FADE_OUT:
		_move_hero()
	if not _released.is_empty() and _t >= FADE_OUT + HOLD:
		if f.ctx.bus != null:
			f.ctx.bus.toast.emit(_released, "info")
		_released = ""
	_show()
	if _t >= FADE_OUT + HOLD + FADE_IN:
		_finish()


func _finish() -> void:
	_t = -1.0
	_released = ""
	var p: Variant = f.ctx.player
	if p != null and _took_input:
		p.input_enabled = true
	_took_input = false
	_show()


## Input handed back mid-fade is the arrest's to give back at the end.
func _hold_input() -> void:
	var p: Variant = f.ctx.player
	if p != null and bool(p.input_enabled):
		_took_input = true
		p.input_enabled = false


## Black over the HUD's overlay (under the pause menu): in over FADE_OUT, held, out over FADE_IN.
func _show() -> void:
	var a := 0.0
	if _t >= 0.0:
		if _t < FADE_OUT:
			a = _t / FADE_OUT
		elif _t < FADE_OUT + HOLD:
			a = 1.0
		else:
			a = clampf(1.0 - (_t - FADE_OUT - HOLD) / FADE_IN, 0.0, 1.0)
	if _layer == null or not is_instance_valid(_layer):
		if a <= 0.0 or f.ctx.hud == null:
			return
		_layer = ColorRect.new()
		_layer.name = "PoliceFade"
		_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var overlay: Control = f.ctx.hud.slot("overlay")
		overlay.add_child(_layer)
		overlay.move_child(_layer, 0)
	_layer.color = Color(0.0, 0.0, 0.0, a)
	_layer.visible = a > 0.0


## Out of the car, and outside the nearest police station when there is one.
func _move_hero() -> void:
	_moved = true
	var p: Variant = f.ctx.player
	if p == null:
		return
	var drive: Object = f.ctx.feature("drive")
	if drive != null and bool(drive.call("exit", true)):
		# Out of the car the hero walks again: the input they get back is the one to restore
		# (it was off at the wheel); the picture is still black.
		_took_input = true
		p.input_enabled = false
	var spot := station_spot(f.ctx.player_position())
	if spot.is_empty():
		return
	p.teleport(spot["pos"], float(spot["yaw"]))
	if f.ctx.mode != null:
		f.ctx.mode.unstick_player()
	_released = "Released outside %s." % str(spot["name"])


## The sidewalk outside the police station nearest from, facing the street ({"pos", "yaw" (deg),
## "name"}); {} when the city has none.
func station_spot(from: Vector3) -> Dictionary:
	var sim: CitySim = f.ctx.sim
	var dir: CityDirectory = f.ctx.directory
	if sim == null or dir == null:
		return {}
	var best := -1
	var road := -1
	var best_d := INF
	for i in sim.active:
		if sim.kind[i] != D.POLICE:
			continue
		var r := dir.frontage(i)
		var dd := Vector2(D.tx(i) - from.x, D.ty(i) - from.z).length_squared()
		if r >= 0 and dd < best_d:
			best_d = dd
			best = i
			road = r
	if best < 0:
		return {}
	var toward := Vector3(D.tx(best) - D.tx(road), 0.0, D.ty(best) - D.ty(road))
	var pos := Vector3(D.tx(road), 0.0, D.ty(road)) + toward * WS.SIDEWALK_CENTER
	var col: Variant = f.ctx.collision
	var g: float = col.ground_height(pos) if col != null else NAN
	pos.y = g if not is_nan(g) else WS.SIDEWALK_TOP
	var label := dir.landmark_name(best)
	return {
		"pos": pos,
		"yaw": rad_to_deg(atan2(toward.x, toward.z)),
		"name": label if not label.is_empty() else "the police station",
	}
