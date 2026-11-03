extends SceneTree
## Ask the five, first-person side (integration feature "arena_ask", scripts/fp/arena/): the chat
## command "/ask <question>" (chat_ask.gd) opens a modal with five columns, one per mayor: the
## person's name with the model badge in a sub-line, a bar that fills while the answer is awaited,
## the finish order 1st..5th, the thought, the post, the proposed orders in plain words with the
## plausibility flags and the source tag. Esc closes it and the modal pops (FpMode returns the
## mouse); the question never reaches the chat feed; a refused ask is a toast; no key text is on
## the page; without a key the columns are recorded or offline and say they did not hear the
## question. The page names models on purpose, so its widgets are re-tagged to their own owner: the
## street's no-branding scan over the HUD stays clean, and no widget outside this panel wears the
## tag. Third person on a grown city, the sim's clock stopped, the five calls held by hand.
## Headless, offline. Prints FP_ARENA_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const KK := preload("res://tools/tests/fp_keyflow_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const LIVE := preload("res://tools/tests/support/arena_live_client.gd")
const ARENA := preload("res://scripts/fp/arena/arena_feature.gd")
const TOKEN := "FP_ARENA_TEST"
## The order the five held calls are released in (mayor indexes, first to land first).
const PERM := [3, 1, 4, 0, 2]
const QUESTION := "Your district lost power. What do you do?"

var fails: Array[String] = []
var ctx: FpContext
var f: ARENA
var chat: FpFeature
var live: LIVE
var toasts: Array[String] = []
var modal_events: Array[bool] = []
var key := KK.long_key()
var _now_ms: int = 0


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	live = LIVE.new()
	live.name = "LiveClient"
	live.live_enabled = true
	live.api_key = key
	live.each = true
	for mi in range(D.MAYORS.size()):
		var m: Dictionary = D.MAYORS[mi]
		live.data_for[str(m["id"])] = {
			"thought": "%s says: lights first." % str(m["name"]),
			"public_post": "Crews are out in %s." % str(m["district"]),
			"actions":
			[
				{"type": "set_tax", "r": 5, "c": 6, "i": 7},
				{"type": "build", "building": "solar_farm", "x": 9000, "y": 9000},
			],
			"propose_ordinance": "",
			"votes": {},
		}
	live.fail["grok"] = "HTTP 429 slow down %s" % key
	ctx = K.make_ctx(get_root(), {"grow": true, "camera_mode": "third", "client": live})
	ctx.player.set_process(false)
	ctx.sim.set_process(false)
	K.make_feature(ctx, "hud_widgets")
	chat = K.make_feature(ctx, "chat")
	f = K.make_feature(ctx, "arena_ask") as ARENA
	check(f != null and chat != null, "the arena and chat features are registered")
	if f == null or chat == null:
		K.finish(self, TOKEN, fails)
		return
	ctx.bus.toast.connect(func(t: String, _kind: String) -> void: toasts.append(t))
	ctx.bus.modal_changed.connect(func(on: bool) -> void: modal_events.append(on))
	ctx.brain.arena_asker().clock = func() -> int: return _now_ms
	_check_flag_and_build()
	_check_chat_parsing()
	await _check_ask_and_race()
	_check_brand_scan()
	await _check_layout()
	_check_close()
	_check_refusals()
	_check_offline_page()
	_check_leave_cases()
	K.finish(self, TOKEN, fails)


func _check_flag_and_build() -> void:
	var spec: Dictionary = (
		JSON.parse_string(FileAccess.get_file_as_string("res://data/feature_flags.json"))["flags"]
	)
	var flag: Dictionary = spec.get("arena_ask", {})
	var desc := str(flag.get("description", ""))
	check(
		(
			bool(flag.get("default", false))
			and desc.contains("five extra live calls")
			and desc.contains("budget")
		),
		"flag arena_ask: default on, the description names the cost and the budget"
	)
	check(
		f.feature_id() == "arena_ask" and FeatureFlags.enabled("arena_ask"),
		"the registry id is the flag name"
	)
	check(
		f.panel != null and f.panel.columns.size() == D.MAYORS.size(),
		"the panel builds five columns"
	)
	check(not f.panel.visible and not f.panel_open and not ctx.is_modal(), "it starts closed")
	var named := true
	for mi in range(D.MAYORS.size()):
		var col: Control = f.panel.columns[mi]
		named = named and (col.get("name_label") as Label).text == D.mayor_display(mi)
	check(named, "each column is headed by the mayor's person name")
	check(f.self_test()["ok"], "self_test passes")


func _check_chat_parsing() -> void:
	var P := preload("res://scripts/fp/chat/chat_ask.gd")
	check(
		P.is_ask("/ask hello") and P.is_ask("  /ASK  hello") and P.is_ask("/ask"),
		"/ask is recognised, any case, bare or with a question"
	)
	check(
		not P.is_ask("/asking") and not P.is_ask("/mayor hi") and not P.is_ask("hello /ask"),
		"other lines are not /ask"
	)
	check(
		P.question_of("/ask  What now? ") == "What now?" and P.question_of("/ask") == "",
		"the question is what follows the command"
	)


## "/ask" from the chat: the modal opens, five calls are in flight, the bars fill, the answers land
## in the order they are released, each column reads right.
func _check_ask_and_race() -> void:
	var feed_n: int = chat.feed.messages.size()
	chat.player_say("/ask " + QUESTION)
	check(f.panel_open and ctx.has_modal(ARENA.MODAL) and f.panel.visible, "/ask opens the modal")
	check(chat.feed.messages.size() == feed_n, "the question is not posted to the chat feed")
	check(
		live.parked.size() == D.MAYORS.size(), "five calls are in flight (%d)" % live.parked.size()
	)
	var all_pending := true
	for c: Control in f.panel.columns:
		all_pending = (
			all_pending
			and bool(c.call("is_pending"))
			and (c.get("rank_label") as Label).text == "…"
		)
	check(all_pending, "every column is waiting")
	_now_ms = 9000
	f.panel._process(0.1)
	var bar: ProgressBar = f.panel.columns[0].get("bar")
	check(
		(
			absf(bar.value - 9.0 / 45.0) < 0.01
			and (f.panel.columns[0].get("time_label") as Label).text == "9.0 s"
		),
		"the bar fills with the seconds waited (%.2f)" % bar.value
	)
	check(
		f.panel.texts().has("Ask the five") and f.panel.texts().has("Thinking…"),
		"the heading and the waiting state show"
	)
	for r in range(PERM.size()):
		_now_ms += 2000
		live.release(int(PERM[r]))
	_check_answers()


## The columns after the five answers landed in the order PERM.
func _check_answers() -> void:
	var order_ok := true
	var rank_texts: Array[String] = []
	# Mayor 4's call failed: it did not race, so the four live answers are 1st to 4th.
	var raced := PERM.filter(func(m: int) -> bool: return m != 4)
	for mi in range(D.MAYORS.size()):
		var c: Control = f.panel.columns[mi]
		var rank := (c.get("rank_label") as Label).text
		rank_texts.append(rank)
		var want := ArenaAsk.ordinal(raced.find(mi) + 1)
		if mi != 4:
			order_ok = order_ok and rank == want
	check(order_ok, "finish order labels follow the landing order (%s)" % str(rank_texts))
	check(
		rank_texts[3] == "1st" and rank_texts[1] == "2nd" and rank_texts[0] == "3rd",
		"a failed call does not take a place: the live answers read 1st, 2nd, 3rd, 4th"
	)
	var shown := true
	for mi in [0, 1, 2, 3]:
		var c: Control = f.panel.columns[mi]
		var all: PackedStringArray = c.call("texts")
		var joined := "\n".join(all)
		shown = (
			shown
			and joined.contains("lights first")
			and joined.contains("Crews are out in")
			and joined.contains("Set taxes to R5/C6/I7")
			and joined.contains("Ordered a Solar Farm")
		)
	check(shown, "thought, post and the orders in plain words show")
	var orders: PackedStringArray = f.panel.columns[0].call("order_lines")
	check(
		(
			orders.size() == 2
			and not orders[0].contains("outside")
			and orders[1].contains("outside the district")
		),
		"the flagged order says why (%s)" % str(orders)
	)
	var sub: HBoxContainer = f.panel.columns[0].get("sub")
	var badge_texts: Array[String] = []
	for b in sub.get_children():
		badge_texts.append(((b as Node).get_child(0) as Label).text)
	check(
		badge_texts == [str(D.MAYORS[0]["name"]), "LIVE"],
		"the sub-line has the model badge and the source tag (%s)" % str(badge_texts)
	)
	var grok: Control = f.panel.columns[4]
	var gt := "\n".join(grok.call("texts"))
	check(
		gt.contains("Live call failed: HTTP 429") and (grok.get("rank_label") as Label).text == "-",
		"a failed call is a red column with the error, no rank"
	)
	var status := f.panel.status.text
	check(
		(
			status.contains(QUESTION)
			and status.contains("4 of 5 answered live, 1 fell back")
			and not status.contains("all five answered")
		),
		"the status line names the question and counts the live answers (%s)" % status
	)
	var texts0: PackedStringArray = f.panel.columns[0].call("texts")
	check(
		(
			texts0.find("Would do") >= 0
			and texts0.find("Would do") < texts0.find("Thought")
			and texts0.find("Would do") < texts0.find("Public post")
		),
		"the orders come before the post and the thought (%s)" % str(texts0)
	)
	check(toasts.is_empty(), "no toast on a good ask")
	var key_seen := KK.leaks("\n".join(f.panel.texts()), key)
	check(not key_seen, "no key text anywhere on the page")


## The street's brand scan stays clean while the page names models; only this panel wears the tag.
func _check_brand_scan() -> void:
	var texts := S.owned_texts(ctx.hud)
	var branded: Array[String] = []
	for t in texts:
		if S.branded(t):
			branded.append(t)
	check(
		branded.is_empty(),
		(
			"the HUD's owned texts stay free of model words with the page open (%s)"
			% str(branded.slice(0, 3))
		)
	)
	var page := "\n".join(f.panel.texts())
	check(
		S.branded(page) and page.contains(str(D.MAYORS[0]["name"])),
		"the page itself names the models"
	)
	var own := _count_owner(f.panel, "arena", true)
	var stray := _count_owner(ctx.hud, "arena", false)
	check(
		own > 20 and stray == 0,
		"the page's widgets are tagged arena (%d) and nothing outside it is (%d)" % [own, stray]
	)
	check(
		_count_owner(f.panel, S.OWNER, true) == 0,
		"no widget of the page is left tagged hud_widgets"
	)


## Five columns side by side inside the panel at 1280x720, none clipped off to the side.
func _check_layout() -> void:
	f.panel.size = Vector2(1280, 720)
	await process_frame
	await process_frame
	var inner := f.panel.get_node("Panel") as Control
	var rect := inner.get_global_rect()
	var widths: Array[int] = []
	var inside := true
	var tall := true
	for c: Control in f.panel.columns:
		var r := c.get_global_rect()
		widths.append(int(r.size.x))
		inside = inside and r.position.x >= rect.position.x and r.end.x <= rect.end.x + 1.0
		tall = tall and r.size.y > 150.0
	var even := true
	for w in widths:
		even = even and absi(w - widths[0]) <= 2 and w >= 190
	check(
		inside and even and tall,
		(
			"five even columns fit the panel at 1280x720 (widths %s, panel %s)"
			% [str(widths), str(rect.size)]
		)
	)
	var scroll := f.panel.get_node("Panel").find_child("Scroll", true, false) as ScrollContainer
	check(
		scroll != null and scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED,
		"the columns can scroll sideways when the window is narrow"
	)
	# A small canvas (a phone-sized web build): the panel shrinks to it, the rest scrolls.
	f.panel.size = Vector2(800, 450)
	await process_frame
	await process_frame
	var small := inner.get_global_rect()
	check(
		small.size.x <= 800.5 and inner.get_combined_minimum_size().x <= 800.0,
		"at 800x450 the panel fits the canvas (%s)" % str(small.size)
	)
	f.panel.size = Vector2(1280, 720)
	await process_frame


func _count_owner(n: Node, owner: String, inside: bool) -> int:
	var c := 0
	if n.get_meta(S.OWNER_META, "") == owner:
		c = 1
	for k in n.get_children():
		if not inside and k == f.panel:
			continue
		c += _count_owner(k, owner, inside)
	return c


func _check_close() -> void:
	modal_events.clear()
	var ev := K.action_event("pause_menu")
	f.panel._input(ev)
	check(
		not f.panel_open and not f.panel.visible and not ctx.is_modal(),
		"Esc closes the panel and pops the modal"
	)
	check(
		modal_events == [false],
		"the modal is released, so FpMode returns the mouse (%s)" % str(modal_events)
	)
	check(not ctx.mode.paused, "Esc did not also open the pause menu")
	# A bare /ask shows the last answers again.
	chat.player_say("/ask")
	var again := "\n".join(f.panel.texts())
	check(
		f.panel_open and again.contains("lights first") and live.parked.size() == D.MAYORS.size(),
		"a bare /ask shows the last answers, asks nobody"
	)
	f.panel.close_requested.emit()
	check(not f.panel_open and not ctx.is_modal(), "the Close button closes it")


func _check_refusals() -> void:
	toasts.clear()
	_now_ms += 10000
	chat.player_say("/ask Again so soon?")
	check(
		toasts.size() == 1 and toasts[0].contains("ask again in"),
		"within a minute the ask is refused with a toast (%s)" % str(toasts)
	)
	check(f.panel_open and f.panel.status.text.contains("ask again in"), "and the panel says so")
	check(live.parked.size() == D.MAYORS.size(), "a refused ask sends no calls")
	f.close_panel()
	# The flag off: /ask is an ordinary chat line.
	FeatureFlags.set_override("arena_ask", false)
	var n: int = chat.feed.messages.size()
	chat.player_say("/ask just a line")
	FeatureFlags.set_override("arena_ask", true)
	check(
		not f.panel_open and chat.feed.messages.size() == n + 1,
		"with the flag off the line goes to the chat as text"
	)


## No key: columns from recordings or the planner, tagged, no calls.
func _check_offline_page() -> void:
	live.live_enabled = false
	live.fail.clear()
	_now_ms += 120000
	var calls := live.sent.size()
	chat.player_say("/ask Anyone home?")
	check(
		f.panel_open and live.sent.size() == calls, "offline: the panel opens and no call goes out"
	)
	var tagged := true
	var ranks := true
	for mi in range(D.MAYORS.size()):
		var c: Control = f.panel.columns[mi]
		var t := "\n".join(c.call("texts"))
		tagged = (
			tagged
			and (
				t.contains("Recorded from another game, did not hear your question.")
				or t.contains("Offline planner, did not hear your question.")
			)
		)
		ranks = ranks and (c.get("rank_label") as Label).text == "-"
		var sub: HBoxContainer = c.get("sub")
		var tag := ((sub.get_child(1) as Node).get_child(0) as Label).text
		tagged = tagged and tag in ["RECORDED", "OFFLINE"]
	check(
		tagged and ranks, "offline columns carry the recorded or offline tag and the note, no rank"
	)
	check(
		f.panel.status.text.contains("models were not asked"),
		"and the status says the models were not asked (%s)" % f.panel.status.text
	)
	var tip: String = f.panel.toggle.tooltip_text
	check(
		tip.contains("No live key"),
		"without a key the persona switch says it changes nothing (%s)" % tip
	)
	# With the switch on, the status must not claim a persona nobody applied.
	f.panel.toggle.button_pressed = true
	_now_ms += 120000
	chat.player_say("/ask Anyone home, with the switch on?")
	var line: String = f.panel.status.text
	check(
		line.contains("not sent") and not line.to_lower().contains("same persona"),
		"offline with the switch on: the question was not sent, no persona claimed (%s)" % line
	)
	f.panel.toggle.button_pressed = false
	f.close_panel()
	live.live_enabled = true


func _check_leave_cases() -> void:
	# Paused: no panel; a pause while open closes it.
	_now_ms += 120000
	chat.player_say("/ask Open then pause")
	check(f.panel_open, "the panel is open for the pause test")
	ctx.bus.pause_changed.emit(true)
	check(not f.panel_open and not ctx.is_modal(), "pausing the game closes it")
	# A new city closes it and forgets the answers.
	_now_ms += 120000
	chat.player_say("/ask Open then new city")
	f.on_world_rebuilt()
	var waiting := "\n".join(f.panel.columns[0].call("texts")).contains("Waiting for a question.")
	check(
		not f.panel_open and not ctx.is_modal() and waiting,
		"a rebuilt world closes it and clears the columns"
	)
	# Teardown frees it and pops the modal.
	_now_ms += 120000
	chat.player_say("/ask Open then leave")
	f.teardown()
	check(not ctx.is_modal() and f.panel == null, "teardown closes and frees the panel")
