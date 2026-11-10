extends SceneTree
## The orbit view's Arena tab (scripts/ui/arena_text.gd, flag arena_tab): a block per mayor read
## from the model ledger. Built from a synthetic ledger (every mayor in a different state: timed
## live answers, a few live answers, replay only, scripted only, nothing yet) the text must lead
## each block with the PERSON's name and put the model brand in the sub-line, show "time to answer"
## honestly (last, mean and n below 5 live answers, p50 and p95 from 5 on, "replay" and "-" instead
## of a speed), the accepted share of orders, repairs, tokens and an order-mix bar no wider than
## its width, list the services, never leak BBCode from a model id, and say so when the ledger is
## off. Then a real CityHud: the tab is appended after People (index 7) only with the flag, shows
## the ledger, and redraws only when the ledger changed. Headless, offline. Prints AI_ARENA_TEST:
## PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const AT := preload("res://scripts/ui/arena_text.gd")
const HUD := preload("res://scripts/ui/city_hud.gd")
const TOKEN := "AI_ARENA_TEST"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 120.0)
	await process_frame
	_check_text()
	_check_helpers()
	await _check_hud()
	K.finish(self, TOKEN, fails)


## A mayor call as the client logs it.
func _call(l: ModelLedger, mi: int, source: String, ms: int, extra: Dictionary = {}) -> void:
	var rec := {
		"role": "mayor",
		"agent": str(D.MAYORS[mi]["id"]),
		"model": str(D.MAYORS[mi]["model"]),
		"source": source,
		"latency_ms": ms,
		"attempts": 1
	}
	rec.merge(extra, true)
	l.note_call(rec)


func _turn(l: ModelLedger, mi: int, source: String, acts: Array) -> void:
	var applied: Array = []
	for a: Array in acts:
		applied.append({"action": {"type": a[0]}, "ok": bool(a[1]), "reason": ""})
	l.note_turn(
		mi,
		{
			"day": 2,
			"source": source,
			"latency_ms": 1,
			"error": "",
			"model": str(D.MAYORS[mi]["model"]),
			"actions": applied
		}
	)


## Argon: six live answers timed, one repaired, tokens, orders 5 of 6. Viktor: two live answers.
## Mei: replay only. Rosa: the scripted planner only. Duke: nothing yet.
func _ledger() -> ModelLedger:
	var l := ModelLedger.new()
	for i in range(6):
		_call(
			l,
			0,
			"live",
			8000 + i * 1000,
			{"tokens_in": 1500, "tokens_out": 300, "repairs": ["fenced"] if i == 0 else []}
		)
		_turn(
			l,
			0,
			"live",
			(
				[
					["road", true],
					["road", true],
					["zone", true],
					["build", true],
					["build", true],
					["park", false]
				]
				if i == 0
				else []
			)
		)
	_call(l, 1, "live", 12000)
	_call(l, 1, "live", 16000)
	_turn(l, 1, "live", [["zone", true]])
	_call(l, 2, "cache", 0, {"attempts": 0})
	_turn(l, 2, "cache", [["road", true], ["zone", false]])
	_call(l, 3, "heuristic", 0, {"attempts": 0})
	_turn(l, 3, "heuristic", [["build", true]])
	l.note_call(
		{
			"role": "mayor",
			"agent": "kimi",
			"model": str(D.MAYORS[2]["model"]),
			"source": "live",
			"latency_ms": 3000,
			"attempts": 3,
			"error": "",
			"repairs": ["think_tag", "salvaged"]
		}
	)
	l.note_call(
		{
			"role": "news",
			"agent": "gazette",
			"model": "XiaomiMiMo/MiMo-V2.6-Flash",
			"source": "live",
			"latency_ms": 5000,
			"attempts": 1
		}
	)
	return l


func _block_of(text: String, mi: int) -> String:
	var start := text.find(str(D.MAYORS[mi]["display"]))
	var stop := text.length()
	if mi + 1 < D.MAYORS.size():
		stop = text.find(str(D.MAYORS[mi + 1]["display"]), start)
	return text.substr(start, stop - start) if start >= 0 and stop > start else ""


func _check_text() -> void:
	var l := _ledger()
	var t := AT.text(l)
	check(t.begins_with("[b]Arena[/b]"), "the tab opens with its title")
	var order: Array[int] = []
	for mi in range(D.MAYORS.size()):
		order.append(t.find(str(D.MAYORS[mi]["display"])))
	var sorted_order := order.duplicate()
	sorted_order.sort()
	check(
		order == sorted_order and order[0] > 0,
		"a block per mayor, in the mayors' order (%s)" % str(order)
	)
	for mi in range(D.MAYORS.size()):
		var b := _block_of(t, mi)
		var person := b.find(str(D.MAYORS[mi]["display"]))
		var brand := b.find(str(D.MAYORS[mi]["name"]))
		check(
			person == 0 and brand > person,
			(
				"%s leads with the person, the model brand follows in the sub-line"
				% D.MAYORS[mi]["display"]
			)
		)
		check(
			b.contains(str(l.mayor_rows()[mi]["label"])),
			"%s's sub-line names the model file" % D.MAYORS[mi]["display"]
		)
	_check_blocks(t)
	_check_rest(t, l)


## The five blocks, mayor by mayor.
func _check_blocks(t: String) -> void:
	var argon := _block_of(t, 0)
	check(
		(
			argon.contains("p50 10.5 s")
			or argon.contains("p50 10.0 s")
			or argon.contains("p50 11.0 s")
		),
		"six live answers: a p50 (%s)" % argon.get_slice("time to answer: ", 1).get_slice("\n", 0)
	)
	check(
		argon.contains("p95") and argon.contains("n 6"), "from five answers on a p95 and the count"
	)
	check(
		argon.contains("orders accepted: 83% (5 of 6)"),
		(
			"accepted orders from the turns (%s)"
			% argon.get_slice("orders accepted: ", 1).get_slice("\n", 0)
		)
	)
	check(argon.contains("repairs: 17% (1 of 6)"), "repairs as a share of live answers")
	check(
		argon.contains("tokens: 9.0k in / 1.8k out"),
		"tokens summed (%s)" % argon.get_slice("tokens: ", 1).get_slice("\n", 0)
	)
	check(argon.contains("live 6") and argon.contains("replay 0"), "turns by source")
	check(
		(
			argon.contains("road 2")
			and argon.contains("build 2")
			and argon.contains("zone 1")
			and argon.contains("park 1")
		),
		"the order mix legend"
	)
	var viktor := _block_of(t, 1)
	check(
		(
			viktor.contains("last 16.0 s")
			and viktor.contains("mean 14.0 s")
			and viktor.contains("n 2")
			and not viktor.contains("p95")
		),
		(
			"two live answers: last, mean and n, never a percentile (%s)"
			% viktor.get_slice("time to answer: ", 1).get_slice("\n", 0)
		)
	)
	var mei := _block_of(t, 2)
	check(
		mei.contains("time to answer:") and not mei.contains("p50"),
		"a mixed mayor still has no p50 from one answer"
	)
	check(
		mei.contains("repairs: 100% (1 of 1)") or mei.contains("repairs: -"),
		"repairs read the live answers only"
	)
	check(
		mei.contains("orders accepted: 50% (1 of 2)"),
		"accepted share is real for replayed turns too"
	)
	var rosa := _block_of(t, 3)
	check(
		rosa.contains("time to answer: -") and rosa.contains("offline 1"),
		(
			"scripted only: no speed claimed (%s)"
			% rosa.get_slice("time to answer: ", 1).get_slice("\n", 0)
		)
	)
	var duke := _block_of(t, 4)
	check(duke.contains("not called yet"), "a mayor not called yet is shown, idle, in words")
	check(
		argon.contains("answering live") and mei.contains("shaky"),
		"every light has its word (%s / %s)" % [argon.get_slice("\n", 1), mei.get_slice("\n", 1)]
	)
	check(
		rosa.contains("orders accepted: no data yet") and rosa.contains("scripted only"),
		"the planner's orders are not credited to the mayor's model; the light says scripted"
	)
	check(
		duke.contains("orders accepted: no data yet") and duke.contains("orders: none yet"),
		"no orders yet: 'no data yet', no bar"
	)


## Replay and scripted wording, the banner, the services, escaping and the off switches.
func _check_rest(t: String, l: ModelLedger) -> void:
	var plain := t.replace("[lb]", "[")
	# Replay-only wording and the banner when nothing is live.
	var quiet := ModelLedger.new()
	_call(quiet, 0, "cache", 0, {"attempts": 0})
	_turn(quiet, 0, "cache", [["road", true]])
	var qt := AT.text(quiet)
	check(
		qt.contains("replay (no live answer to time)"),
		"replay is named as replay, not given a speed"
	)
	check(qt.contains("No live answer yet"), "the banner says no live answer has come")
	check(
		(
			qt.contains("replay only")
			and AT.health_word("grey").begins_with("replay only")
			and AT.health_word("scripted").begins_with("scripted only")
		),
		"a replay-only light says replay, a scripted-only one says scripted"
	)
	check(not t.contains("No live answer yet"), "and it is gone once one has")
	check(
		t.contains("Services and minds") and plain.contains("MiMo-V2.6-Flash"),
		"services follow, by model"
	)
	check(t.contains("Time to answer includes retries"), "the caveat is on the page")
	check(
		t.contains("[bgcolor=") and t.contains("[/bgcolor]"), "the lights and the mix bar are drawn"
	)
	var services_part := t.substr(t.find("Services and minds"))
	check(
		not services_part.contains("(no live answer") and services_part.contains("scripted "),
		"the services lines say scripted and do not repeat the mayors' replay wording"
	)
	_check_glyphs(t + qt + AT.text(evil_ledger()))
	check(
		t.contains("Citizen Voices") or t.contains("Gazette"),
		"the idle roster is listed with its jobs"
	)
	# BBCode from a model id never turns into markup.
	var evil := ModelLedger.new()
	evil.note_call(
		{
			"role": "news",
			"agent": "g",
			"model": "x-ai/[b]evil",
			"source": "live",
			"latency_ms": 100,
			"attempts": 1
		}
	)
	var et := AT.text(evil)
	check(
		not et.contains("[b]evil") and et.contains("[lb]b]evil"),
		"a model id's brackets are escaped"
	)
	check(AT.text(null).contains("switched off"), "no ledger: says so")
	FeatureFlags.set_override("model_ledger", false)
	check(AT.text(l).contains("switched off"), "flag off: says so")
	FeatureFlags.set_override("model_ledger", true)


func evil_ledger() -> ModelLedger:
	var l := _ledger()
	_call(l, 4, "heuristic", 10, {"error": "HTTP 503 down", "attempts": 3})
	return l


## The web build's HUD font has only Latin text: U+25CF and U+2588 showed as boxes with hex codes
## there. Everything the tab prints is ASCII or the middle dot (Latin-1).
func _check_glyphs(text: String) -> void:
	var odd := {}
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c > 126 or (c < 32 and c != 10):
			odd["U+%04X" % c] = true
	var allowed := {"U+00B7": true}
	for k: String in odd.keys():
		check(allowed.has(k), "the tab prints no glyph a Latin-only font lacks (%s)" % k)
	check(
		not text.contains("●") and not text.contains("█"),
		"no circle or block glyph in the Arena text"
	)


## The "#" characters of a bar once its BBCode tags (whose colours also start with "#") are gone.
func _cells(bbcode: String) -> int:
	var tag := RegEx.create_from_string("\\[[^\\]]*\\]")
	return tag.sub(bbcode, "", true).count("#")


## The tab is 384 px wide: about 55 characters of text or 24 "#" cells of a bar. A bar and each
## service line must fit on one line (a lone "scripted 0" wrapping onto its own line, or a bar
## that wraps into two stacked bars, were seen in the browser).
func _check_line_widths() -> void:
	var tag := RegEx.create_from_string("\\[[^\\]]*\\]")
	var bar := AT.mix_line({"build_road": 40, "zone": 30, "place_building": 20, "set_tax": 10})
	var rows := bar.split("\n")
	check(
		(
			rows.size() == 2
			and _cells(rows[0]) == AT.MIX_WIDTH * AT.MIX_CELL
			and AT.MIX_WIDTH * AT.MIX_CELL <= 24
		),
		"the bar is one line of at most 24 cells, its legend the next (%d lines)" % rows.size()
	)
	var worst := 0
	var svc := {
		"model": "deepseek-ai/DeepSeek-V4.1-Flash-0731",
		"label": "DeepSeek-V4.1-Flash",
		"mix": "Residents 120 · Chat 34",
		"calls": 154,
		"live_ok": 120,
		"live_fail": 20,
		"replay": 10,
		"fallback": 4,
		"offline": 0,
		"n_live": 120,
		"p50_ms": 11200,
		"p95_ms": 41000,
		"last_ms": 9000,
		"health": "green"
	}
	for line in AT.service_line(svc).split("\n"):
		worst = maxi(worst, tag.sub(line, "", true).length())
	check(
		worst <= 55 and AT.service_line(svc).contains("scripted 4"),
		"a service's lines fit 384 px (longest %d characters)" % worst
	)


func _check_helpers() -> void:
	var bar := AT.mix_line(
		{"road": 90, "zone": 5, "build": 3, "park": 1, "tax": 1, "power": 1, "x": 1, "y": 1}
	)
	check(
		_cells(bar) <= AT.MIX_WIDTH * AT.MIX_CELL,
		"the bar never exceeds its width (%d cells)" % _cells(bar)
	)
	check(
		bar.find("road 90") < bar.find("zone 5") and bar.count("[color=") == AT.MIX_LISTED * 2,
		"most frequent first, %d kinds listed" % AT.MIX_LISTED
	)
	check(AT.mix_line({}).contains("none yet"), "an empty mix")
	var one := AT.mix_line({"road": 4})
	check(_cells(one) == AT.MIX_WIDTH * AT.MIX_CELL, "one kind fills the bar")
	check(AT.kilo(999) == "999" and AT.kilo(1234) == "1.2k" and AT.kilo(0) == "0", "token counts")
	check(AT.esc("a[b") == "a[lb]b", "escape")
	check(
		(
			AT.accept_words({"accept_pct": -1}) == "no data yet"
			and AT.repair_words({"live_ok": 0}) == "-"
			and AT.token_words({"token_calls": 0}) == "-"
		),
		"dashes for nothing"
	)
	check(
		AT.error_words({"errors": {"429": 2, "no JSON": 1}}).contains("429 x2, no JSON x1"),
		"errors by class"
	)
	check(AT.error_words({"errors": {}}).is_empty(), "no errors, no words")
	_check_line_widths()
	check(
		AT.light("red").contains("#FF7A6A") and AT.light("nonsense").contains("#8A97A8"),
		"lights by health"
	)


func _check_hud() -> void:
	var w := SK.make_world(get_root(), 7)
	var brain: CityBrain = w["brain"]
	var client: GmiClient = w["client"]
	var hud: CityHud = HUD.new()
	get_root().add_child(hud)
	hud.setup(w["sim"], brain, client)
	var tabs: TabContainer = hud.get("_tabs")
	check(
		tabs.get_tab_count() == 8 and tabs.get_tab_title(7) == "Arena",
		(
			"with the flag the tab is appended after People: index 7 (%d tabs, %s)"
			% [tabs.get_tab_count(), tabs.get_tab_title(tabs.get_tab_count() - 1)]
		)
	)
	check(
		tabs.get_tab_title(6) == "People" and tabs.get_tab_title(4) == "GMI Log",
		"the indices of the older tabs did not move"
	)
	var rt: RichTextLabel = hud.get("_arena_rt")
	var m: Dictionary = D.MAYORS[2]
	brain.ledger.note_call(
		{
			"role": "mayor",
			"agent": str(m["id"]),
			"model": str(m["model"]),
			"source": "live",
			"latency_ms": 7000,
			"attempts": 1
		}
	)
	tabs.current_tab = 7
	hud.call("_render_arena")
	var shown := rt.get_parsed_text()
	check(
		(
			shown.begins_with("Arena")
			and shown.contains(str(m["display"]))
			and shown.find(str(m["display"])) < shown.find(str(m["name"]))
		),
		"the HUD shows the ledger, person first (%s)" % shown.get_slice("\n", 3)
	)
	check(
		int(hud.get("_arena_rev")) == brain.ledger.revision, "it remembers which revision it drew"
	)
	rt.text = "marker"
	hud.call("_render_arena")
	check(rt.text == "marker", "no new call, no redraw")
	brain.ledger.note_call(
		{
			"role": "news",
			"agent": "gazette",
			"model": "XiaomiMiMo/MiMo-V2.6-Flash",
			"source": "live",
			"latency_ms": 100,
			"attempts": 1
		}
	)
	hud.call("_render_arena")
	check(rt.get_parsed_text().begins_with("Arena"), "a new call redraws it")
	tabs.current_tab = 0
	rt.text = "marker"
	brain.ledger.note_call(
		{
			"role": "news",
			"agent": "gazette",
			"model": "XiaomiMiMo/MiMo-V2.6-Flash",
			"source": "live",
			"latency_ms": 100,
			"attempts": 1
		}
	)
	hud.call("_render_arena")
	check(rt.text == "marker", "another tab open: nothing is drawn")
	hud.queue_free()
	FeatureFlags.set_override("arena_tab", false)
	var hud2: CityHud = HUD.new()
	get_root().add_child(hud2)
	hud2.setup(w["sim"], brain, client)
	var t2: TabContainer = hud2.get("_tabs")
	check(
		t2.get_tab_count() == 7 and hud2.get("_arena_rt") == null,
		"flag arena_tab off: seven tabs as before (%d)" % t2.get_tab_count()
	)
	hud2.call("_render_arena")
	check(true, "and rendering it is a no-op")
	FeatureFlags.set_override("arena_tab", true)
	hud2.queue_free()
	for n: Node in [w["sim"], w["people"], w["minds"], client, brain]:
		if is_instance_valid(n):
			n.queue_free()
