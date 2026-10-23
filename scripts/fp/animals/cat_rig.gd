extends "res://scripts/fp/animals/dog_rig.gd"
## A cat's life on top of its clip (CatBodies puts one on every cat skeleton): the tail sways from
## the tip (wag 0..1, from a lazy sway to the lashing of a hunter or an angry cat) and droops back
## from the clip's carriage (droop 0..1; the clips stand it up, a frightened cat's hangs low); the
## head turns toward look and lifts with each meow (bark) as a dog's does.

const CAT_TAIL: Array[String] = ["Tail1", "Tail2", "Tail3", "Tail4"]
## Swing of each tail bone at full sway, root to tip (rad), the beat from a lazy sway to a lash
## (Hz) and the lag from one bone to the next (rad of the beat).
const SWAY: Array[float] = [0.06, 0.18, 0.32, 0.45]
const SWAY_HZ := Vector2(0.35, 2.4)
const SWAY_LAG := 0.8
## Turn of the tail's first two bones about the model's right axis at full droop (rad, back and
## down).
const DROOP_ANGLE: Array[float] = [0.7, 0.25]

var droop: float = 0.0


func calm() -> void:
	super()
	droop = 0.0


func _tail_pose(sk: Skeleton3D, delta: float) -> void:
	var w := clampf(wag, 0.0, 1.0)
	_phase = fmod(_phase + TAU * lerpf(SWAY_HZ.x, SWAY_HZ.y, w) * delta, TAU)
	var down := clampf(droop, 0.0, 1.0)
	for k in range(_tail.size()):
		if k < DROOP_ANGLE.size() and down > 0.01:
			_turn(sk, _tail[k], _right, DROOP_ANGLE[k] * down)
		if w > 0.01:
			var a := SWAY[mini(k, SWAY.size() - 1)] * w * sin(_phase - SWAY_LAG * k)
			_turn(sk, _tail[k], _up, a)
