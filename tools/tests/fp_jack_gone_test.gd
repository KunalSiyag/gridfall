extends SceneTree
## The landing of a carjack's throw (person_landed: reactions.gd tells it as the body touches the
## ground) is what shakes the camera (hit_feel) and sounds the fall (audio), so a driver who is no
## longer in the street by then (removed, gone indoors, a rebuilt city's) lands for nobody: neither
## comes. Someone who stays lands as ever, once. The reactions are the real ones, stepped by hand
## over bare walkers; the whole flow through a grown city is fp_carjack_test's.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const DT := 1.0 / 60.0
const SEED := 12
const STRENGTH := CJ.STRENGTH
const HALF_W := 0.9 * WS.M

var fails: Array[String] = []
var ran: Array[String] = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_gone()
	Engine.time_scale = 1.0
	FeatureFlags.reload()
	K.check(fails, ran.size() == 1, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_GONE_TEST", fails)


## One carjack thrown through the real reactions with the camera and the audio listening: stayed
## (lands: one shake, one fall), removed from the street (in the haul, in the air: nothing), the
## world rebuilt under it (the reactions dropped: nothing).
func _check_gone() -> void:
	var ctx := K.make_ctx(get_root(), {"audio": true, "camera_mode": "third"})
	var hf := K.make_feature(ctx, "hit_feel")
	var af := K.make_feature(ctx, "audio")
	if hf == null or af == null:
		K.check(fails, false, "hit_feel and audio are registered")
		return
	hf.set_process(false)
	af.set_process(false)
	var em: Node = af.get("emitters")
	var origin: Vector3 = em.call("listener")
	for row: Array in [
		["stays", -1.0, 1], ["removed in the haul", 0.3, 0], ["removed in the air", 0.7, 0]
	]:
		var s := _throw(ctx, origin)
		var wk: WK = s["wk"]
		var w: WK.Walker = s["w"]
		var re: RE = s["re"]
		var shots := int(em.get("shots_played"))  # with the yank's thump
		_settle(hf)
		var shakes := int(hf.get("shakes"))  # and its shake
		var t := 0.0
		while re.count() > 0 and t < 6.0:
			if float(row[1]) >= 0.0 and t >= float(row[1]) and not w.dead:
				wk.remove(w)
			re.step(DT)
			t += DT
		var shook := int(hf.get("shakes")) - shakes
		var sounded := int(em.get("shots_played")) - shots
		K.check(
			fails,
			shook == int(row[2]) and sounded == int(row[2]),
			(
				"%s: %d shake and %d fall sound after the yank (%d, %d)"
				% [row[0], row[2], row[2], shook, sounded]
			)
		)
	# A city rebuilt while they are in the air drops the reactions: the landings never come.
	var s2 := _throw(ctx, origin)
	var re2: RE = s2["re"]
	_settle(hf)
	var shakes2 := int(hf.get("shakes"))
	var shots2 := int(em.get("shots_played"))
	re2.step(0.3)
	re2.clear()
	hf.call("on_world_rebuilt")
	af.call("from_dict", {})
	for _k in range(120):
		re2.step(DT)
	K.check(
		fails,
		int(hf.get("shakes")) == shakes2 and int(em.get("shots_played")) == shots2,
		"a rebuilt city, the reactions dropped mid-air: no landing shake and no fall"
	)
	hf.call("teardown")
	af.call("teardown")
	ran.append("gone")


## A driver drawn at the wheel thrown by a carjack beside origin: the stage (the walkers, the
## reactions told of the landing as traffic tells the bus) and the blow's yank on the bus.
func _throw(ctx: FpContext, origin: Vector3) -> Dictionary:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	wk.stand(w, origin + Vector3(HALF_W + CJ.OUT, 0.0, 0.0), 0.0)
	w.state = "walk"
	w.seated = true
	var re := RE.new()
	re.setup(wk, null, SEED)
	re.on_landed = func(who: WK.Walker) -> void:
		ctx.bus.person_landed.emit(who.pos + who.vis_off, who.id)
	var src := origin + Vector3(HALF_W + WS.M, 0.0, 0.5 * WS.M)
	var res := re.hit(w, src, Vector3.RIGHT, STRENGTH, "carjack", CJ.JACK_FLING)
	re.drag_out(w, origin + Vector3(0.45 * WS.M, 0.15 * WS.M, 0.0), 0.0)
	var info := {
		"strength": STRENGTH, "down": true, "by": -1, "lands_in": res["lands_in"], "walker": w.id
	}
	ctx.bus.person_hit.emit(origin, "carjack", info)
	return {"wk": wk, "w": w, "re": re}


## The yank's hit-stop run out.
func _settle(hf: FpFeature) -> void:
	for _k in range(8):
		hf.call("tick", DT)
