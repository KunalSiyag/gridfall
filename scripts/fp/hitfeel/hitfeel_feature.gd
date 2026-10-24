extends FpFeature
## Hit feel (integration feature "hit_feel"; docs/fp/ARCHITECTURE.md, Hit feel): what a blow feels
## like. A blow of the hero's that lands (person_hit "punch" or "shove") freezes the world for a few
## hundredths of a second (hit-stop: Engine.time_scale dips to STOP_SCALE for real seconds, longer
## for a harder blow and one that knocks them down) and shakes the camera (the player's shake).
## Someone the player's car knocks down, a blow on the hero (hero_hurt) and a crash in the car
## (car_impact) shake it too, the hardest of them with a shorter stop; a kick or a swing landing on
## an animal (animal_hit) stops and shakes less than one on a person. The thrown body of a
## knock-down is traffic's (reactions.gd, under the same flag). Nothing stops in photo mode, while
## the game is paused or at sim speeds above 1.

const WS := preload("res://scripts/fp/world_scale.gd")
## The world's time scale through a hit-stop.
const STOP_SCALE := 0.05
## A blow of the hero's: the stop (real seconds) from the weakest to the hardest blow, and DOWN_STOP
## more when it knocks them down; the shake trauma likewise.
const BLOW_STOP := Vector2(0.045, 0.09)
const DOWN_STOP := 0.03
const BLOW_SHAKE := Vector2(0.12, 0.42)
const DOWN_SHAKE := 0.15
## Someone the player's car hits: shake trauma by strength, and the stop when they go down.
const CAR_SHAKE := Vector2(0.25, 0.6)
const CAR_STOP := 0.06
## A blow of the hero's on an animal (animal_hit): the stop and the trauma by strength.
const ANIMAL_STOP := Vector2(0.03, 0.06)
const ANIMAL_SHAKE := Vector2(0.08, 0.25)
## A blow on the hero (hero_hurt): trauma HURT_SHAKE.x plus the health lost over HURT_SHAKE.y, and
## the stop by cause (none for a fall or a crash, which car_impact shakes).
const HURT_SHAKE := Vector2(0.2, 50.0)
const HURT_STOP := {"punch": 0.05, "bite": 0.04, "car": 0.08}
## A crash: trauma by the closing speed (m/s) from CRASH_V.x up to full at CRASH_V.y.
const CRASH_V := Vector2(2.0, 18.0)
const CRASH_SHAKE := Vector2(0.15, 0.85)
## The longest stop asked for at once (s).
const STOP_MAX := 0.15

## Hit-stops and shakes so far (tests).
var stops: int = 0
var shakes: int = 0
## Real seconds the stop under way has left, and the time scale to give back.
var _stop_left: float = 0.0
var _base_scale: float = 1.0
var _last_us: int = 0


func feature_id() -> String:
	return "hit_feel"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_us = Time.get_ticks_usec()
	if ctx.bus != null:
		link_signal(ctx.bus.person_hit, _on_person_hit)
		link_signal(ctx.bus.hero_hurt, _on_hero_hurt)
		link_signal(ctx.bus.car_impact, _on_car_impact)
		link_signal(ctx.bus.animal_hit, _on_animal_hit)


func teardown() -> void:
	unlink_signals()
	_end_stop()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var real := float(now - _last_us) / 1e6
	_last_us = now
	tick(real)


## Runs the stop under way on by real seconds; gives the time scale back once it is over.
func tick(real_dt: float) -> void:
	if _stop_left <= 0.0:
		return
	_stop_left -= real_dt
	if _stop_left <= 0.0:
		_end_stop()


## True while a hit-stop holds the world.
func stopped() -> bool:
	return _stop_left > 0.0


## Freezes the world for secs real seconds (a longer one already under way stands).
func hit_stop(secs: float) -> void:
	if secs <= 0.0 or not _open():
		return
	if ctx.mode != null and ctx.mode.time_scale > 1:
		return
	if _stop_left <= 0.0:
		_base_scale = Engine.time_scale
	_stop_left = maxf(_stop_left, minf(secs, STOP_MAX))
	Engine.time_scale = STOP_SCALE
	stops += 1


## Shakes the camera by trauma (0..1).
func shake(trauma: float) -> void:
	if trauma <= 0.0 or not _open() or ctx.player == null:
		return
	ctx.player.shake(trauma)
	shakes += 1


func _end_stop() -> void:
	if is_equal_approx(Engine.time_scale, STOP_SCALE):
		Engine.time_scale = _base_scale
	_stop_left = 0.0


func _open() -> bool:
	if ctx == null or ctx.player == null or ctx.player.photo_mode:
		return false
	return not (is_inside_tree() and get_tree().paused)


func _on_person_hit(_at: Vector3, cause: String, info: Dictionary) -> void:
	var s := clampf(float(info.get("strength", 0.5)), 0.0, 1.0)
	var down := bool(info.get("down", false))
	match cause:
		"punch", "shove":
			hit_stop(lerpf(BLOW_STOP.x, BLOW_STOP.y, s) + (DOWN_STOP if down else 0.0))
			shake(lerpf(BLOW_SHAKE.x, BLOW_SHAKE.y, s) + (DOWN_SHAKE if down else 0.0))
		"car":
			if down:
				hit_stop(CAR_STOP)
			shake(lerpf(CAR_SHAKE.x, CAR_SHAKE.y, s))


func _on_animal_hit(_at: Vector3, _kind: String, strength: float) -> void:
	var s := clampf(strength, 0.0, 1.0)
	hit_stop(lerpf(ANIMAL_STOP.x, ANIMAL_STOP.y, s))
	shake(lerpf(ANIMAL_SHAKE.x, ANIMAL_SHAKE.y, s))


func _on_hero_hurt(amount: float, cause: String, _health: float, _down: bool) -> void:
	if cause == "crash":
		return
	shake(HURT_SHAKE.x + amount / HURT_SHAKE.y)
	hit_stop(float(HURT_STOP.get(cause, 0.0)))


func _on_car_impact(_at: Vector3, speed: float, _what: String) -> void:
	var k := inverse_lerp(CRASH_V.x, CRASH_V.y, speed / WS.M)
	if k <= 0.0:
		return
	shake(lerpf(CRASH_SHAKE.x, CRASH_SHAKE.y, minf(k, 1.0)))


func self_test() -> Dictionary:
	var ok := is_equal_approx(Engine.time_scale, 1.0) or stopped()
	return {
		"ok": ok, "detail": "stops=%d shakes=%d scale=%.2f" % [stops, shakes, Engine.time_scale]
	}
