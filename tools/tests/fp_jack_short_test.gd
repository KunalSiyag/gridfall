extends SceneTree
## A carjack's throw at the flings a car beside the door leaves (jack_throw.gd, the carjack_throw
## flag; the default 1.8 m is fp_carjack_throw_test's): the haul ends at the pace the flight carries
## on at, whatever the fling, down to a standstill for a hop too short to ask any, so the body is
## neither hauled out at one speed and left to crawl nor stopped at the door; and the twist is
## scaled to the air time so a hop is not a spin, never faster than SPIN_RATE, the default throw's
## own twist untouched. Bare walkers with no collision world, stepped by hand.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const JT := preload("res://scripts/fp/traffic/jack_throw.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const DT := 1.0 / 60.0
const SEED := 12
const HALF_W := 0.9 * WS.M
const SEAT := Vector3(0.45 * WS.M, 0.15 * WS.M, -0.2 * WS.M)
const FLINGS: Array[float] = [0.5, 0.8, 1.0, 1.3, 1.8]

var fails: Array[String] = []
var ran: Array[String] = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_plan()
	_check_paces()
	_check_twist_rate()
	FeatureFlags.reload()
	K.check(fails, ran.size() == 3, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_SHORT_TEST", fails)


## The plan alone: the spin is the strength's, or less where the air is short enough that the
## turning would pass SPIN_RATE; the pull ends at the plan's m1 whatever it is, 0 to 2.5.
func _check_plan() -> void:
	var door := Vector3.RIGHT
	var worst := 0.0
	var uncapped := true
	for s: float in [0.0, 0.3, 0.7, 0.85, 1.0]:
		for fling: float in FLINGS:
			var p := JT.make(s, fling, door, 1.0)
			worst = maxf(worst, absf(p.spin) * PI / p.air)
			var want := lerpf(JT.SPIN.x, JT.SPIN.y, s)
			if fling >= 1.8 and not is_equal_approx(p.spin, want):
				uncapped = false
	K.check(
		fails,
		worst <= JT.SPIN_RATE + 1e-6,
		(
			"no plan turns the body faster than SPIN_RATE at its fastest (%.2f of %.1f rad/s)"
			% [worst, JT.SPIN_RATE]
		)
	)
	K.check(fails, uncapped, "the default 1.8 m throw keeps its twist, whatever the blow")
	var hop := JT.make(CJ.STRENGTH, 0.5, door, 1.0)
	var full := JT.make(CJ.STRENGTH, 1.8, door, 1.0)
	K.check(
		fails,
		absf(hop.spin) < absf(full.spin),
		(
			"a 0.5 m hop twists less than the full throw (%.2f against %.2f rad)"
			% [absf(hop.spin), absf(full.spin)]
		)
	)
	for m1: float in [0.0, 0.25, 0.5, 1.0, 2.5]:
		var h := 1e-4
		var slope := (JT.pull(1.0, m1) - JT.pull(1.0 - h, m1)) / h
		var mono := true
		var prev := 0.0
		for k in range(1, 201):
			var v := JT.pull(float(k) / 200.0, m1)
			mono = mono and v >= prev - 1e-9
			prev = v
		K.check(
			fails,
			absf(slope - m1) < 0.01 and mono and is_equal_approx(prev, 1.0),
			"the pull ends at speed %.2f and only goes forward on the way" % m1
		)
	ran.append("plan")


## The haul's end speed against the flight's start speed, drawn feet over the clips' frames, for
## each fling: the same (the pull ends at the plan's own pace). The haul's is its last step (the
## frame the knockback starts on), the flight's the second one after: a steady pace through the air.
func _check_paces() -> void:
	for fling: float in FLINGS:
		var a := _throw(fling)
		var p: JT.Plan = a["plan"]
		var k := _first(a, &"knockback")
		var f: Array = a["frames"]
		var pre := _flat((f[k][1] as Vector3) - (f[k - 1][1] as Vector3)) / DT
		var post := _flat((f[k + 2][1] as Vector3) - (f[k + 1][1] as Vector3)) / DT
		var want := JT.release_speed(p) * WS.M
		K.check(
			fails,
			absf(post - want) < 0.05 * want and absf(pre - post) < 0.15 * post,
			(
				"%.1f m: hauled out at %.2f m/s, on at %.2f (the plan's %.2f), m1 %.2f"
				% [fling, pre / WS.M, post / WS.M, want / WS.M, p.m1]
			)
		)
	ran.append("paces")


## The fastest the body turns in the flight, over the knockback frames' yaw: under SPIN_RATE (with a
## frame's slack), whatever the fling.
func _check_twist_rate() -> void:
	for fling: float in FLINGS:
		var a := _throw(fling)
		var f: Array = a["frames"]
		var fastest := 0.0
		for i in range(1, f.size()):
			if f[i][5] == &"knockback" and f[i - 1][5] == &"knockback":
				fastest = maxf(
					fastest, absf(angle_difference(float(f[i - 1][2]), float(f[i][2]))) / DT
				)
		K.check(
			fails,
			fastest <= JT.SPIN_RATE * 1.02,
			(
				"%.1f m: the body turns at most %.1f rad/s (SPIN_RATE %.1f)"
				% [fling, fastest, JT.SPIN_RATE]
			)
		)
	ran.append("twist_rate")


# ------------------------------------------------------------------ the stage


## One carjack of the given fling through reactions.gd, a driver drawn at the wheel of a car at
## rest, stepped by hand to the reaction's end: {"plan", "frames"} with a frame [t, drawn feet, yaw,
## tilt, roll, react clip].
func _throw(fling: float) -> Dictionary:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	wk.stand(w, Vector3(HALF_W + CJ.OUT, 0.0, SEAT.z), 0.0)
	w.state = "walk"
	var re := RE.new()
	re.setup(wk, null, SEED)
	w.seated = true
	var src := Vector3(HALF_W + 1.0 * WS.M, 0.0, 0.5 * WS.M)
	re.hit(w, src, Vector3.RIGHT, CJ.STRENGTH, "carjack", fling)
	var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
	var out := {"plan": r.jack, "frames": []}
	re.drag_out(w, SEAT, 0.0)
	var frames: Array = out["frames"]
	var t := 0.0
	while re.count() > 0 and t < 12.0:
		re.step(DT)
		t += DT
		frames.append([t, w.pos + w.vis_off, w.yaw, w.vis_tilt, w.vis_roll, w.react])
	return out


## The index of the first frame on clip.
func _first(a: Dictionary, clip: StringName) -> int:
	var f: Array = a["frames"]
	for i in range(f.size()):
		if f[i][5] == clip:
			return i
	return -1


func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
