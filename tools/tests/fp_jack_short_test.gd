extends SceneTree
## A carjack's pull-out at the drops a car beside the door leaves (jack_pull.gd, the carjack_throw
## flag; the default carjack.gd DROP_M is fp_jack_pull_test's): the haul ends at the pace the slide
## carries on at, whatever the drop, down to a standstill for a hop too short to ask any, so the
## body is neither hauled out at one speed and left to crawl nor stopped at the door; and the body
## keeps the facing it sat with through the haul and the fall, however short. Bare walkers with no
## collision world, stepped by hand.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const JP := preload("res://scripts/fp/traffic/jack_pull.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const DT := 1.0 / 60.0
const SEED := 12
const HALF_W := 0.9 * WS.M
const SEAT := Vector3(0.45 * WS.M, 0.15 * WS.M, -0.2 * WS.M)
const DROPS: Array[float] = [0.2, 0.3, 0.4, 0.5, 0.6]

var fails: Array[String] = []
var ran: Array[String] = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_plan()
	_check_paces()
	_check_facing()
	FeatureFlags.reload()
	K.check(fails, ran.size() == 3, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_SHORT_TEST", fails)


## The pull ends at the plan's speed m1 whatever it is, 0 to 2.5, and only goes forward on the way.
func _check_plan() -> void:
	for m1: float in [0.0, 0.25, 0.5, 1.0, 2.5]:
		var h := 1e-4
		var slope := (JP.pull(1.0, m1) - JP.pull(1.0 - h, m1)) / h
		var mono := true
		var prev := 0.0
		for k in range(1, 201):
			var v := JP.pull(float(k) / 200.0, m1)
			mono = mono and v >= prev - 1e-9
			prev = v
		K.check(
			fails,
			absf(slope - m1) < 0.01 and mono and is_equal_approx(prev, 1.0),
			"the pull ends at speed %.2f and only goes forward on the way" % m1
		)
	ran.append("plan")


## The haul's end speed against the slide's start speed, drawn feet over the frames, for each drop:
## the same (the pull ends at the plan's own pace, twice the drop over the slide's seconds, as the
## slide eases out), to the frame's average (the haul's last step runs a little above the speed the
## pull ends at, more for a longer span). The haul's is its last step, the slide's the first after.
func _check_paces() -> void:
	for drop: float in DROPS:
		var a := _pull(drop)
		var k := _first(a, "place")
		var f: Array = a["frames"]
		var pre := _flat((f[k][1] as Vector3) - (f[k - 1][1] as Vector3)) / DT
		var post := _flat((f[k + 1][1] as Vector3) - (f[k][1] as Vector3)) / DT
		var want := 2.0 * drop * WS.M / JP.SLIDE_S
		K.check(
			fails,
			absf(post - want) < 0.1 * want and absf(pre - post) < 0.35 * post,
			(
				"%.1f m: hauled out at %.2f m/s, on at %.2f (the plan's %.2f), m1 %.2f"
				% [drop, pre / WS.M, post / WS.M, want / WS.M, (a["plan"] as JP.Plan).m1]
			)
		)
	ran.append("paces")


## The body keeps the facing it sat with (along the car, yaw 0) all the way through the haul, the
## fall, the lie and the get-up (the walk back or the run off after turns it), whatever the drop.
func _check_facing() -> void:
	for drop: float in DROPS:
		var a := _pull(drop)
		var f: Array = a["frames"]
		var turned := 0.0
		for i in range(f.size()):
			if f[i][5] == "drag" or f[i][5] == "place":
				turned = maxf(turned, absf(angle_difference(0.0, float(f[i][2]))))
		K.check(
			fails,
			turned < 1e-4,
			"%.1f m: faces as they sat all the way (turned %.4f rad)" % [drop, turned]
		)
	ran.append("facing")


# ------------------------------------------------------------------ the stage


## One carjack of the given drop through reactions.gd, a driver drawn at the wheel of a car at
## rest, stepped by hand to the reaction's end: {"plan", "frames"} with a frame [t, drawn feet, yaw,
## tilt, roll, the reaction's mode].
func _pull(drop: float) -> Dictionary:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	wk.stand(w, Vector3(HALF_W + CJ.OUT, 0.0, SEAT.z), 0.0)
	w.state = "walk"
	var re := RE.new()
	re.setup(wk, null, SEED)
	w.seated = true
	var src := Vector3(HALF_W + 1.0 * WS.M, 0.0, 0.5 * WS.M)
	re.hit(w, src, Vector3.RIGHT, CJ.STRENGTH, "carjack", drop)
	var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
	var out := {"plan": r.jack, "frames": []}
	re.drag_out(w, SEAT, 0.0)
	var frames: Array = out["frames"]
	var t := 0.0
	while re.count() > 0 and t < 12.0:
		re.step(DT)
		t += DT
		frames.append([t, w.pos + w.vis_off, w.yaw, w.vis_tilt, w.vis_roll, r.mode])
	return out


## The index of the first frame in mode.
func _first(a: Dictionary, mode: String) -> int:
	var f: Array = a["frames"]
	for i in range(f.size()):
		if f[i][5] == mode:
			return i
	return -1


func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
