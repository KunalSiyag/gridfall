extends SceneTree
## The landing of a carjack's throw (jack_throw.gd, the carjack_throw flag with hit_feel): the
## camera shakes at the yank and again as the driver's body comes down, and the fall sounds there
## (person_landed: reactions.gd tells it on the frame the throw touches the ground), not on a timer
## after the yank: at 1x, 4x and 8x sim speed alike (the body runs on sim seconds), once, for the
## driver the blow promised only, dropped by a load or a rebuilt city. The bus events are sent by
## hand first, then the whole chain over real reactions stepped by hand (a driver no longer in
## the street is fp_jack_gone_test's).

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const DT := 1.0 / 60.0
const SEED := 12
## The car's driver's side +X: half its width, where the seat's feet are in it and the blow.
const HALF_W := 0.9 * WS.M
const SEAT := Vector3(0.45 * WS.M, 0.15 * WS.M, -0.2 * WS.M)
const STRENGTH := CJ.STRENGTH
const FLING := CJ.JACK_FLING

var fails: Array[String] = []
var ran: Array[String] = []
var ctx: FpContext
var hf: FpFeature


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_hit_feel()
	_check_fall_sound()
	_check_landing_speed()
	Engine.time_scale = 1.0
	FeatureFlags.reload()
	K.check(fails, ran.size() == 3, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_TOUCHDOWN_TEST", fails)


## hit_feel: a carjack's yank stops the world a moment and shakes the camera, and the landing the
## blow's info promises shakes it again as that driver's body comes down (person_landed); nothing
## for anyone else's landing or a blow that promises none, nothing with the flag off, nothing from
## someone else's blow; a load or a rebuilt city drops the landing still to come.
func _check_hit_feel() -> void:
	ctx = K.make_ctx(get_root(), {"camera_mode": "third"})
	hf = K.make_feature(ctx, "hit_feel")
	if hf == null:
		K.check(fails, false, "the hit_feel feature is registered")
		return
	hf.set_process(false)
	var info := {"strength": STRENGTH, "down": true, "by": -1, "lands_in": 0.95, "walker": 7}
	var s0 := int(hf.get("shakes"))
	var t0 := int(hf.get("stops"))
	ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", info)
	K.check(
		fails,
		int(hf.get("shakes")) == s0 + 1 and int(hf.get("stops")) == t0 + 1,
		"the yank shakes the camera and stops the world a moment"
	)
	_settle(hf)
	K.check(fails, is_equal_approx(Engine.time_scale, 1.0), "the stop runs out")
	ctx.bus.person_landed.emit(Vector3.ZERO, 3)
	K.check(fails, int(hf.get("shakes")) == s0 + 1, "someone else landing shakes nothing")
	ctx.bus.person_landed.emit(Vector3.ZERO, 7)
	K.check(fails, int(hf.get("shakes")) == s0 + 2, "one as the driver's body comes down")
	ctx.bus.person_landed.emit(Vector3.ZERO, 7)
	K.check(fails, int(hf.get("shakes")) == s0 + 2, "and only the one")
	ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", {"strength": STRENGTH, "down": true})
	ctx.bus.person_landed.emit(Vector3.ZERO, -1)
	ctx.bus.person_landed.emit(Vector3.ZERO, 7)
	K.check(fails, int(hf.get("shakes")) == s0 + 3, "with no landing time given, the yank alone")
	_settle(hf)
	FeatureFlags.set_override("carjack_throw", false)
	ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", info)
	ctx.bus.person_landed.emit(Vector3.ZERO, 7)
	K.check(fails, int(hf.get("shakes")) == s0 + 3, "flag off: a carjack shakes nothing, as before")
	FeatureFlags.set_override("carjack_throw", true)
	for drop: String in ["from_dict", "on_world_rebuilt"]:
		ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", info)
		var shook := int(hf.get("shakes"))
		if drop == "from_dict":
			hf.call("from_dict", {})
		else:
			hf.call("on_world_rebuilt")
		ctx.bus.person_landed.emit(Vector3.ZERO, 7)
		K.check(
			fails,
			int(hf.get("shakes")) == shook,
			"a load or a rebuilt city drops the landing still to come (%s)" % drop
		)
		_settle(hf)
	hf.call("teardown")
	Engine.time_scale = 1.0
	ran.append("hit_feel")


## The audio feature: a carjack's body lands (body_fall) as person_landed says, where it lands, not
## on a timer after the yank; a landing nobody promised, or promised and gone, is silent; with no
## landing time told it is BODY_FALL_S after the yank as before.
func _check_fall_sound() -> void:
	var actx := K.make_ctx(get_root(), {"audio": true})
	var f: FpFeature = K.make_feature(actx, "audio")
	if f == null:
		K.check(fails, false, "the audio feature is registered")
		return
	f.set_process(false)
	var em: Node = f.get("emitters")
	var at: Vector3 = em.call("listener") + Vector3(0.05, 0.0, 0.0)
	var landing := at + Vector3(0.1, 0.0, 0.0)
	var info := {"strength": STRENGTH, "down": true, "walker": 9, "lands_in": 0.9}
	# The shots since each step: the yank, the promised time, another's landing, theirs, again.
	var seen: Array[int] = []
	var last := int(em.get("shots_played"))
	var steps := [
		func() -> void: actx.bus.person_hit.emit(at, "carjack", info),
		func() -> void: _play(f, 3.0),
		func() -> void: actx.bus.person_landed.emit(landing, 4),
		func() -> void: actx.bus.person_landed.emit(landing, 9),
		func() -> void: actx.bus.person_landed.emit(landing, 9),
	]
	for step: Callable in steps:
		step.call()
		seen.append(int(em.get("shots_played")) - last)
		last = int(em.get("shots_played"))
	var src: Variant = em.call("source", "shot:%d" % last)
	var named: bool = src != null and (src as RefCounted).get("stream") == BANK.stream("body_fall")
	var there: bool = (
		src != null and ((src as RefCounted).get("pos") as Vector3).is_equal_approx(landing)
	)
	var story := "thump at the yank, none on a timer, none for another's landing, the fall as"
	story += " that body lands, once"
	K.check(fails, seen == [1, 0, 0, 1, 0] and named, "%s (%s)" % [story, str(seen)])
	K.check(fails, there, "and it sounds where the body lands, not at the door")
	_play(f, 2.0)
	# No landing time told: the plain fall, BODY_FALL_S after the yank.
	var n := int(em.get("shots_played"))
	actx.bus.person_hit.emit(at, "carjack", {"strength": STRENGTH, "down": true})
	var thump := int(em.get("shots_played")) - n
	_play(f, BANK.BODY_FALL_S - 0.1)
	var early := int(em.get("shots_played")) - n - thump
	_play(f, 0.2)
	var fall := int(em.get("shots_played")) - n - thump - early
	var plain := "no landing time told: the plain fall BODY_FALL_S on"
	K.check(
		fails,
		thump == 1 and early == 0 and fall == 1,
		"%s (%d %d %d)" % [plain, thump, early, fall]
	)
	_play(f, 2.0)
	# Gone before it lands: the throw never lands, nothing sounds; a load drops what was waiting.
	var m := int(em.get("shots_played"))
	info["walker"] = 11
	actx.bus.person_hit.emit(at, "carjack", info)
	f.call("from_dict", {})
	actx.bus.person_landed.emit(landing, 11)
	var dropped := int(em.get("shots_played")) - m
	K.check(fails, dropped == 1, "a load drops the landing waiting: the yank's thump only")
	f.call("teardown")
	ran.append("fall_sound")


## The landing follows the body, not the clock: with the whole chain (reactions' touchdown, the
## bus, hit_feel and audio) the camera shakes and the fall sounds on the frame the throw touches the
## ground, whatever the sim's pace (1x, 4x, 8x: the body runs on sim seconds) and not before.
func _check_landing_speed() -> void:
	var lctx := K.make_ctx(get_root(), {"audio": true, "camera_mode": "third"})
	var hfx: FpFeature = K.make_feature(lctx, "hit_feel")
	var af: FpFeature = K.make_feature(lctx, "audio")
	if hfx == null or af == null:
		K.check(fails, false, "hit_feel and audio are registered")
		return
	hfx.set_process(false)
	af.set_process(false)
	var em: Node = af.get("emitters")
	var origin: Vector3 = em.call("listener")
	for speed: float in [1.0, 4.0, 8.0]:
		var wk := WK.new()
		wk.setup(null, null, null, null, SEED)
		var w := wk.make("ambient")
		wk.stand(w, origin + Vector3(HALF_W + CJ.OUT, 0.0, SEAT.z), 0.0)
		w.state = "walk"
		w.seated = true
		var re := RE.new()
		re.setup(wk, null, SEED)
		re.on_landed = func(who: WK.Walker) -> void:
			lctx.bus.person_landed.emit(who.pos + who.vis_off, who.id)
		var res := re.hit(
			w,
			origin + Vector3(HALF_W + WS.M, 0.0, 0.5 * WS.M),
			Vector3.RIGHT,
			STRENGTH,
			"carjack",
			FLING
		)
		var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
		re.drag_out(w, origin + SEAT, 0.0)
		var info := {
			"strength": STRENGTH,
			"down": true,
			"by": -1,
			"lands_in": res["lands_in"],
			"walker": w.id
		}
		var shakes := int(hfx.get("shakes"))
		var shots := int(em.get("shots_played"))
		lctx.bus.person_hit.emit(origin, "carjack", info)
		_settle(hfx)
		shakes = int(hfx.get("shakes"))  # the yank's
		shots = int(em.get("shots_played"))  # and its thump
		var dt := speed * DT
		var t := 0.0
		var landed_at := -1.0
		var down_at := -1.0
		var early := 0
		while re.count() > 0 and t < 6.0:
			re.step(dt)
			t += dt
			if down_at < 0.0 and r.fly_t >= r.air and r.air > 0.0 and r.jack.landed:
				down_at = t
			var shook := int(hfx.get("shakes")) > shakes
			var sounded := int(em.get("shots_played")) > shots
			if (shook or sounded) and landed_at < 0.0:
				landed_at = t
				early += 0 if down_at >= 0.0 else 1
				K.check(
					fails,
					shook and sounded,
					(
						"at %.0fx the shake and the fall come together (%s, %s)"
						% [speed, shook, sounded]
					)
				)
		K.check(
			fails,
			down_at > 0.0 and absf(landed_at - down_at) < 1e-9 and early == 0,
			(
				"at %.0fx both come as the body touches the ground (%.3f; body down at %.3f sim s)"
				% [speed, landed_at, down_at]
			)
		)
		K.check(
			fails,
			absf(down_at - float(res["lands_in"])) <= dt + 1e-6,
			"as planned: %.3f sim s on, %.3f told" % [down_at, float(res["lands_in"])]
		)
		K.check(
			fails,
			int(hfx.get("shakes")) == shakes + 1 and int(em.get("shots_played")) == shots + 1,
			(
				"once each (%d shake, %d sound)"
				% [int(hfx.get("shakes")) - shakes, int(em.get("shots_played")) - shots]
			)
		)
	hfx.call("teardown")
	af.call("teardown")
	Engine.time_scale = 1.0
	ran.append("landing_speed")


## The yank's hit-stop run out.
func _settle(f: FpFeature) -> void:
	for _k in range(8):
		f.call("tick", DT)


## Steps the audio feature seconds on.
func _play(f: FpFeature, seconds: float) -> void:
	for _k in range(roundi(seconds / DT)):
		f.call("step", DT)
