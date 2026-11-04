extends SceneTree
## The press run (feature "activity"): a campaign poster that a live image model printed
## (bus.poster_ready with meta.source "live") is a feed card with the image model's badge and the
## mayor it campaigns for. Split from fp_activity_test.gd to keep that file under the lint cap.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const FT := preload("res://tools/tests/support/feed_text.gd")

var fails: Array[String] = []
var announced: Array[String] = []  # bus.ai_decision_shown, in order


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"grow": true, "camera_mode": "third"})
	K.make_feature(ctx, "hud_widgets")
	var f := K.make_feature(ctx, "activity") as FpFeature
	K.check(fails, f != null, "the activity feature is registered")
	if f == null:
		K.finish(self, "FP_ACTIVITY_PRESS_TEST", fails)
		return
	ctx.bus.ai_decision_shown.connect(func(a: String) -> void: announced.append(a))
	_check_press(ctx, f)
	K.finish(self, "FP_ACTIVITY_PRESS_TEST", fails)


## The press run: a campaign poster that a live image model printed (bus.poster_ready with
## meta.source "live") is a card with the image model's badge and the mayor it campaigns for; a
## pre-baked, procedural or disk poster, a poster that is not a campaign and a malformed payload add
## nothing.
func _check_press(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var items: Array = f.get("items")
	var before := items.size()
	var told := announced.size()
	var live := {
		"key": "k1",
		"kind": "campaign_kimi",
		"texture": null,
		"meta": {"kind": "campaign_kimi", "source": "live"}
	}
	ctx.bus.poster_ready.emit(live)
	K.check(
		fails,
		items.size() == mini(before + 1, 12),
		"a live campaign poster adds a card (%d items)" % items.size()
	)
	var card: Control = feed.call("open_card")
	var mi := D.mayor_index("kimi")
	K.check(
		fails,
		FT.text(card, "Headline") == "Campaign poster printed",
		"it says so (%s)" % FT.text(card, "Headline")
	)
	K.check(
		fails,
		FT.text(card, "Who") == D.mayor_display(mi),
		"naming the mayor by person, not the model (%s)" % FT.text(card, "Who")
	)
	K.check(
		fails,
		FT.badge(card, "Model") == "hy-image-v3.5-preview",
		"with the image model's badge (%s)" % FT.badge(card, "Model")
	)
	K.check(
		fails, FT.badge(card, "Source") == "LIVE", "tagged LIVE (%s)" % FT.badge(card, "Source")
	)
	K.check(
		fails,
		FT.text(card, "Where") == str(D.MAYORS[mi]["district"]),
		"placed in the mayor's district (%s)" % FT.text(card, "Where")
	)
	var re := RegEx.create_from_string(FT.LEAK_RE)
	var leaks := PackedStringArray()
	for t in S.owned_texts(card):
		if re.search(t) != null:
			leaks.append(t)
	K.check(fails, leaks.is_empty(), "no brand word in its owned text (%s)" % str(leaks))
	K.check(
		fails,
		announced.size() == told + 1 and announced[-1] == str(mi),
		"it announces itself on the bus once"
	)
	var n := items.size()
	for meta: Dictionary in [
		{"source": "prebaked"},
		{"source": "procedural"},
		{"source": "disk"},
		{"source": "memory"},
		{}
	]:
		ctx.bus.poster_ready.emit(
			{"key": "k2", "kind": "campaign_argon", "texture": null, "meta": meta}
		)
	ctx.bus.poster_ready.emit(
		{"key": "k3", "kind": "shop_cafe", "texture": null, "meta": {"source": "live"}}
	)
	ctx.bus.poster_ready.emit(
		{"key": "k4", "kind": "campaign_nobody", "texture": null, "meta": {"source": "live"}}
	)
	ctx.bus.poster_ready.emit(
		{"key": "k5", "kind": "campaign_grok", "texture": null, "meta": "live"}
	)
	ctx.bus.poster_ready.emit({"key": "k6", "kind": 7, "texture": null})
	K.check(fails, items.size() == n, "other posters add nothing (%d items)" % items.size())
	# The list is capped (12), so its size alone cannot see a card that was added and pushed
	# another out: every added card announces itself, and only the live one did.
	K.check(
		fails,
		announced.size() == told + 1,
		"no rejected poster made a card (%d announced, one expected)" % (announced.size() - told)
	)
