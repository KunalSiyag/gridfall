extends SceneTree
## The landing of a carjack's throw (person_hit "lands_in") is told ahead and happens later, so the
## camera shake (hit_feel) and the fall thump (audio) wait on a timer; if the driver is no longer in
## the street by then (traffic's walker_here: removed, gone indoors) neither comes. Someone the
## street still has lands as ever, and a blow that names nobody (or a street that cannot say) still
## shakes and thumps. The traffic feature is a stub that says who is gone; the real one's
## walker_here is fp_carjack_test's.

const K := preload("res://tools/tests/fp_kit.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const DT := 1.0 / 60.0
const STRENGTH := 0.85
const LANDS := 0.95

var fails: Array[String] = []
var ran: Array[String] = []


## Traffic as the two features see it: who is in the street.
class TrafficStub:
	extends FpFeature
	var gone := {}

	func feature_id() -> String:
		return "traffic"

	func walker_here(id: int) -> bool:
		return not gone.has(id)


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_shake()
	_check_thump()
	Engine.time_scale = 1.0
	FeatureFlags.reload()
	K.check(fails, ran.size() == 2, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_GONE_TEST", fails)


## The camera: the landing shake comes for a driver still there, not for one gone before it, and
## comes for a blow that names nobody.
func _check_shake() -> void:
	var ctx := K.make_ctx(get_root(), {"camera_mode": "third"})
	var hf := K.make_feature(ctx, "hit_feel")
	if hf == null:
		K.check(fails, false, "the hit_feel feature is registered")
		return
	hf.set_process(false)
	var traffic := TrafficStub.new()
	ctx.features["traffic"] = traffic
	var info := {"strength": STRENGTH, "down": true, "by": -1, "lands_in": LANDS, "walker": 5}
	var s0 := int(hf.get("shakes"))
	ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", info)
	_settle(hf)
	hf.call("tick_landings", LANDS + 0.1)
	K.check(
		fails,
		int(hf.get("shakes")) == s0 + 2,
		"a driver still in the street: the yank shakes and so does the landing"
	)
	info["walker"] = 6
	ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", info)
	_settle(hf)
	var after_yank := int(hf.get("shakes"))
	traffic.gone[6] = true
	hf.call("tick_landings", 0.5)
	hf.call("tick_landings", LANDS)
	K.check(
		fails,
		int(hf.get("shakes")) == after_yank,
		"one gone from the street before they land: no landing shake"
	)
	hf.call("tick_landings", 5.0)
	K.check(fails, int(hf.get("shakes")) == after_yank, "and none later, the entry spent")
	info.erase("walker")
	ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", info)
	_settle(hf)
	var named_none := int(hf.get("shakes"))
	hf.call("tick_landings", LANDS + 0.1)
	K.check(fails, int(hf.get("shakes")) == named_none + 1, "a blow that names nobody still lands")
	ctx.features.erase("traffic")
	info["walker"] = 6
	ctx.bus.person_hit.emit(Vector3.ZERO, "carjack", info)
	_settle(hf)
	var blind := int(hf.get("shakes"))
	hf.call("tick_landings", LANDS + 0.1)
	K.check(
		fails,
		int(hf.get("shakes")) == blind + 1,
		"with no traffic to ask, the landing comes as ever"
	)
	hf.call("teardown")
	traffic.free()
	ran.append("shake")


## The fall thump: sounds at the landing for a driver still there, not for one gone; a throw
## the info tells no landing of (a punch's, a brawl's) is the plain BODY_FALL_S one as before.
func _check_thump() -> void:
	var actx := K.make_ctx(get_root(), {"audio": true})
	var f: FpFeature = K.make_feature(actx, "audio")
	if f == null:
		K.check(fails, false, "the audio feature is registered")
		return
	f.set_process(false)
	var traffic := TrafficStub.new()
	actx.features["traffic"] = traffic
	var em: Node = f.get("emitters")
	var at: Vector3 = em.call("listener") + Vector3(0.05, 0.0, 0.0)
	for row: Array in [
		["there", 5, false, 1], ["gone", 6, true, 0], ["no walker named", -1, true, 1]
	]:
		var info := {"strength": STRENGTH, "down": true, "lands_in": LANDS}
		if int(row[1]) >= 0:
			info["walker"] = int(row[1])
		var n := int(em.get("shots_played"))
		actx.bus.person_hit.emit(at, "carjack", info)
		var thump := int(em.get("shots_played")) - n
		if bool(row[2]) and int(row[1]) >= 0:
			traffic.gone[int(row[1])] = true
		_play(f, LANDS + 0.2)
		var fall := int(em.get("shots_played")) - n - thump
		K.check(
			fails,
			thump == 1 and fall == int(row[3]),
			(
				"%s: the thump at the yank, %d fall sound at the landing (%d, %d)"
				% [row[0], row[3], thump, fall]
			)
		)
		_play(f, 2.0)
	var n2 := int(em.get("shots_played"))
	actx.bus.person_hit.emit(at, "punch", {"strength": STRENGTH, "down": true, "walker": 6})
	traffic.gone[6] = true
	_play(f, BANK.BODY_FALL_S + 0.2)
	K.check(
		fails,
		int(em.get("shots_played")) - n2 == 2,
		"a blow with no landing time told: the thump and the plain fall, as before"
	)
	actx.features.erase("traffic")
	f.call("teardown")
	traffic.free()
	ran.append("thump")


## The yank's hit-stop run out.
func _settle(hf: FpFeature) -> void:
	for _k in range(8):
		hf.call("tick", DT)


## Steps the audio feature seconds on.
func _play(f: FpFeature, seconds: float) -> void:
	for _k in range(roundi(seconds / DT)):
		f.call("step", DT)
