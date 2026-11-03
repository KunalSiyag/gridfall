extends SceneTree
## The street's live badge ("activity" feature) must not cry wolf. It reads "down" (Reconnecting)
## when the breaker is not closed or more than half of the recent live calls failed, and one failed
## call out of one is 100%: a single 401, a stray timeout or the first call after boot used to turn
## it red. The ratio now counts only from GmiClient.LIVE_BADGE_MIN_OUTCOMES live outcomes on
## (fewer keep the neutral "live" state), and the ops alert rule keeps its stricter min_calls.

const K := preload("res://tools/tests/fp_kit.gd")

var fails: Array[String] = []


## A client whose transport answers from a script (no network).
class FakeNet:
	extends GmiClient
	var reply: Dictionary = {}

	func _post(
		_model: String, _system: String, _user: String, _max_tokens: int, _timeout_s: float
	) -> Dictionary:
		return reply.duplicate()


func _init() -> void:
	K.watchdog(self, "FP_LIVE_BADGE_TEST")
	await process_frame
	var client := FakeNet.new()
	client.name = "GmiClient"
	client.live_enabled = true
	client.api_key = "badge_test_key_0123456789"
	var ctx := K.make_ctx(get_root(), {"camera_mode": "third", "client": client})
	ctx.player.set_process(false)
	K.make_feature(ctx, "hud_widgets")
	var f: FpFeature = K.make_feature(ctx, "activity")
	if f == null:
		K.check(fails, false, "the activity feature is registered")
		K.finish(self, "FP_LIVE_BADGE_TEST", fails)
		return
	f.set_process(false)
	_check_constant()
	_check_ratio(client)
	_check_badge(client, f)
	await _check_flow(client, f)
	K.finish(self, "FP_LIVE_BADGE_TEST", fails)


## The badge state the street shows after a refresh ("live", "down" or "offline").
func _state(f: FpFeature) -> String:
	f.call("_refresh")
	return str((f.get("feed") as Control).call("state"))


func _set_outcomes(c: GmiClient, outcomes: Array) -> void:
	c.live_outcomes.clear()
	for o: Variant in outcomes:
		c.live_outcomes.append(bool(o))


func _check_constant() -> void:
	var rules: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/alert_rules.json")
	)
	var alert_min := 0
	for r: Dictionary in (rules as Dictionary).get("rules", []):
		if str(r.get("id", "")) == "gmi_live_failures":
			alert_min = int(r.get("min_calls", 0))
	var n := GmiClient.LIVE_BADGE_MIN_OUTCOMES
	K.check(
		fails,
		n >= 3 and alert_min >= n,
		(
			"the badge needs at least 3 outcomes (%d), no more than the alert's min_calls (%d)"
			% [n, alert_min]
		)
	)


func _check_ratio(c: GmiClient) -> void:
	var table := [
		[[], 0.0],
		[[false], 0.0],
		[[false, false], 0.0],
		[[false, false, false], 1.0],
		[[false, true, false], 2.0 / 3.0],
		[[true, true, true, false], 0.25],
	]
	var bad: Array[String] = []
	for row: Array in table:
		_set_outcomes(c, row[0])
		if not is_equal_approx(c.live_failure_ratio(), float(row[1])):
			bad.append("%s -> %s" % [row[0], c.live_failure_ratio()])
	K.check(fails, bad.is_empty(), "the failure ratio is 0 until 3 outcomes are in %s" % [bad])
	c.live_outcomes.clear()


func _check_badge(c: GmiClient, f: FpFeature) -> void:
	c.live_enabled = false
	K.check(fails, not c.replay_cache.is_empty(), "the test client has the recorded replay")
	K.check(fails, _state(f) == "replay", "no live play with recorded answers reads Replay")
	var recorded := c.replay_cache
	c.replay_cache = {}
	K.check(fails, _state(f) == "offline", "no live play and nothing recorded reads Offline")
	c.replay_cache = recorded
	c.live_enabled = true
	_set_outcomes(c, [])
	K.check(fails, _state(f) == "live", "no calls yet is the neutral Live state")
	_set_outcomes(c, [false])
	K.check(fails, _state(f) == "live", "one failure of one call is not red")
	_set_outcomes(c, [false, false])
	K.check(fails, _state(f) == "live", "two failures of two calls are not red either")
	_set_outcomes(c, [false, false, false])
	K.check(fails, _state(f) == "down", "three failures of three calls are red (Reconnecting)")
	_set_outcomes(c, [false, true, true])
	K.check(fails, _state(f) == "live", "one failure in three calls is Live")
	_set_outcomes(c, [false, false, true])
	K.check(fails, _state(f) == "down", "two failures in three calls (0.67) are past the line")
	_set_outcomes(c, [false, true, false, false])
	K.check(fails, _state(f) == "down", "and so are three of four")
	_set_outcomes(c, [false, false, true, true])
	K.check(fails, _state(f) == "live", "half failing is not past the 0.5 line")
	_set_outcomes(c, [false, false, false, true, true, true, true])
	K.check(fails, _state(f) == "live", "the badge recovers as successes arrive")
	var mixed: Array = []
	for _i in range(19):
		mixed.append(true)
	mixed.append(false)
	_set_outcomes(c, mixed)
	K.check(fails, _state(f) == "live", "one stray failure among many successes stays Live")
	_set_outcomes(c, [])
	c.breaker.record_failure()
	c.breaker.record_failure()
	c.breaker.record_failure()
	c.breaker.record_failure()
	K.check(
		fails,
		_state(f) == "down",
		"an open breaker still reads Reconnecting with no samples at all"
	)
	c.breaker.reset()
	c.live_outcomes.clear()
	K.check(fails, _state(f) == "live", "and it clears when the breaker closes")


## The same, driven by real calls through the client (live_json), not by writing the outcomes.
func _check_flow(c: FakeNet, f: FpFeature) -> void:
	c.live_enabled = true
	c.reply = {"ok": false, "error": "HTTP 401 nope", "http": 401, "service_fail": false}
	await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(
		fails,
		c.live_outcomes.size() == 1 and _state(f) == "live",
		"flow: the first failed call leaves the badge on Live"
	)
	await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, _state(f) == "live", "flow: the second failed call too")
	await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(
		fails,
		c.breaker_state() == "closed" and _state(f) == "down",
		"flow: the third failed call turns it to Reconnecting (breaker still closed)"
	)
	c.reply = {"ok": true, "data": {"say": "hi"}, "http": 200}
	for _i in range(4):
		await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, _state(f) == "live", "flow: four good calls bring it back to Live")
