extends SceneTree
## The street league's model-ledger columns (scripts/fp/reporter/league_ledger.gd, flag
## model_ledger): Orders (the share of a mayor's orders the city carried out), Speed (the median
## time to answer, "replay" or "-"), a health light by each mayor's name, and the Services & minds
## page behind Tab. No model or brand word in the owned text of either page. Headless, offline.
## Prints FP_LEAGUE_LEDGER_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const DESK := preload("res://scripts/fp/reporter/reporter_desk.gd")
const REPORTER := preload("res://scripts/fp/reporter/reporter_feature.gd")

var fails: Array[String] = []
var ctx: FpContext
var f: REPORTER


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	ctx.sim.set_process(false)
	K.make_feature(ctx, "hud_widgets")
	K.make_feature(ctx, "chat")
	f = K.make_feature(ctx, "reporter") as REPORTER
	K.check(fails, f != null and f.league != null, "fixture: the reporter feature and its league")
	if f == null or f.league == null:
		K.finish(self, "FP_LEAGUE_LEDGER_TEST", fails)
		return
	f.set_process(false)
	_feed()
	_check_columns()
	await _check_fit()
	await _check_pages()
	_check_flag_off()
	K.finish(self, "FP_LEAGUE_LEDGER_TEST", fails)


func _send(e: InputEvent) -> void:
	f._unhandled_input(e)


## A mayor's call as the client logs it.
func _call(mi: int, source: String, ms: int, attempts: int, err: String = "") -> void:
	var rec := {
		"role": "mayor", "agent": str(D.MAYORS[mi]["id"]), "model": str(D.MAYORS[mi]["model"])
	}
	rec.merge({"source": source, "latency_ms": ms, "attempts": attempts, "error": err})
	ctx.brain.ledger.note_call(rec)


## A support agent's call.
func _service(role: String, source: String, ms: int, attempts: int, err: String = "") -> void:
	var rec := {"role": role, "agent": "x", "model": str(D.SUPPORT_AGENTS[role]["model"])}
	rec.merge({"source": source, "latency_ms": ms, "attempts": attempts, "error": err})
	ctx.brain.ledger.note_call(rec)


## Mayor 0: three timed live answers (good); 1: a recording only (replay); 2: two failed calls
## (down); 3: the scripted planner only; 4: nothing. The Gazette answered live, the Council Speaker
## failed twice.
func _feed() -> void:
	ctx.brain.ledger.clear()
	for ms in [8000, 10000, 12000]:
		_call(0, "live", ms, 1)
	_call(1, "cache", 0, 0)
	for _i in range(2):
		_call(2, "heuristic", 90, 3, "HTTP 503 down")
	_call(3, "heuristic", 0, 0)
	# The sim's own whole-city count differs on purpose: with the ledger on, the league reads the
	# ledger's, the same counter as the Arena tab.
	ctx.sim.mayors[0]["actions_ok"] = 30
	ctx.sim.mayors[0]["actions_rejected"] = 30
	var acts: Array = []
	for i in range(52):
		acts.append({"action": {"type": "road"}, "ok": i >= 6, "reason": ""})
	ctx.brain.ledger.note_turn(0, {"source": "live", "actions": acts, "model": "x", "day": 2})
	ctx.sim.mayors[1]["actions_ok"] = 0
	ctx.sim.mayors[1]["actions_rejected"] = 0
	_service("news", "live", 5000, 1)
	for _i in range(2):
		_service("council", "heuristic", 70, 3, "HTTP 429 slow")


## Orders, Speed and the light of every mayor, and no brand word.
func _check_columns() -> void:
	f.open_league()
	var rows := DESK.standings(ctx.sim, ctx.residents)
	var table: GridContainer = f.league.get("_table")
	var cols: int = f.league.COLS.size()
	var heads: Array[String] = []
	for c in table.get_children().slice(0, cols):
		heads.append(str((c as Label).text))
	var heads_ok := heads.slice(7, 9) == ["Orders", "Speed"] and heads[-1] == "Score"
	K.check(fails, heads_ok, "the table has Orders and Speed before Score (%s)" % str(heads))
	var want := {
		0: ["88%", "10.0 s", "green"],
		1: ["no data", "replay", "grey"],
		2: ["no data", "-", "red"],
		3: ["no data", "-", "scripted"],
		4: ["no data", "-", "idle"],
	}
	var dots: PackedStringArray = f.league.health_dots()
	var good := 0
	var seen: Array[String] = []
	for k in range(rows.size()):
		var mi := int(rows[k]["mi"])
		var cells := table.get_children()
		var orders_cell := str(f.league.call("_cell_text", cells[cols * (k + 1) + 7]))
		var speed_cell := str(f.league.call("_cell_text", cells[cols * (k + 1) + 8]))
		var light: String = dots[k] if k < dots.size() else "?"
		seen.append("%d:%s/%s/%s" % [mi, orders_cell, speed_cell, light])
		var w: Array = want[mi]
		good += int(orders_cell == w[0] and speed_cell == w[1] and light == w[2])
	var cell_msg := "Orders, Speed and the light of each mayor (%s)" % str(seen)
	K.check(fails, good == rows.size() and dots.size() == rows.size(), cell_msg)
	var branded := _branded()
	var lines := f.league.table_lines()
	var brand_msg := "no brand word in the street league's owned text (%s)" % str(branded)
	K.check(fails, branded.is_empty() and lines.size() == rows.size(), brand_msg)
	var tip: String = (table.get_child(cols + 1).get_child(0) as Control).tooltip_text
	var tip_msg := "the light has a plain tooltip (%s)" % tip
	K.check(fails, not tip.is_empty() and not S.branded(tip), tip_msg)


## The owned texts of the league that match the brand regex.
func _branded() -> Array[String]:
	var out: Array[String] = []
	for t in S.owned_texts(f.league):
		if S.branded(t):
			out.append(t)
	return out


## The text of a label as it is drawn (heading cells are upper-cased), and its width in px.
func _drawn_width(l: Label) -> float:
	var text := l.text.to_upper() if l.uppercase else l.text
	var font := l.get_theme_font("font")
	return (
		font
		. get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size"))
		. x
	)


## Cells whose text is wider than their column (a clipped, ellipsised cell), in a grid.
func _clipped(grid: GridContainer) -> Array[String]:
	var out: Array[String] = []
	for cell in grid.get_children():
		var labels: Array[Label] = []
		if cell is Label:
			labels.append(cell)
		else:
			for n in cell.get_children():
				if n is Label:
					labels.append(n)
				elif n.get_child_count() > 0 and n.get_child(0) is Label:
					labels.append(n.get_child(0))
		var budget := (cell as Control).custom_minimum_size.x
		var used := 0.0
		for l in labels:
			used += _drawn_width(l)
		if labels.size() > 1:
			used += 40.0
		if used > budget and not labels.is_empty():
			out.append("%s (%d > %d)" % [labels[0].text, int(used), int(budget)])
	return out


## Every district name is shown whole, and the columns (Orders, Speed and the health light too) fit
## the panel's inner width at 1280x720: the District column was cut to 120 px to make room for
## them and showed "Southeast Boo..." (seen in the browser).
func _check_fit() -> void:
	var cols: Array = f.league.COLS
	var total := float(cols.size() - 1) * float(f.league.GAP)
	for c: Array in cols:
		total += float(c[1])
	var inner: float = f.league.WIDTH - 2.0 * f.league.MARGIN
	K.check(
		fails, total <= inner, "the columns fit the panel (%d of %d px)" % [int(total), int(inner)]
	)
	K.check(fails, f.league.WIDTH <= 1000.0, "the panel leaves room at 1280 px wide")
	f.open_league()
	await process_frame
	var table: GridContainer = f.league.get("_table")
	var clipped := _clipped(table)
	K.check(fails, clipped.is_empty(), "no cell of the mayors' table is cut (%s)" % str(clipped))
	var districts := PackedStringArray()
	for m: Dictionary in D.MAYORS:
		districts.append(str(m["district"]))
	var lines := "\n".join(f.league.table_lines())
	var whole := true
	for d in districts:
		whole = whole and lines.contains(d)
	K.check(fails, whole, "all five district names are in the table")
	# The longest strings the numeric columns can hold in a long game.
	var rows := DESK.standings(ctx.sim, ctx.residents)
	rows[0]["pop"] = 999999
	rows[0]["jobs"] = 999999
	rows[0]["funds"] = -12345678
	rows[0]["orders_text"] = "100%"
	rows[0]["speed"] = "111.2 s"
	f.league.show_league(
		rows, {"day": "Day 99", "press": "", "assignment": "", "leads": [], "stories": []}
	)
	var worst := _clipped(table)
	K.check(
		fails,
		worst.is_empty(),
		"nor with six-figure counts, debt and a slow speed (%s)" % str(worst)
	)
	K.check(fails, f.league.table_lines().size() == rows.size(), "fixture: five rows")
	# Orders before any order was counted: dim "no data" with its tooltip.
	var cells := table.get_children()
	var cols_n: int = cols.size()
	var no_data := cells[cols_n * 2 + 7] as Label
	K.check(
		fails,
		no_data.text == "no data" and no_data.tooltip_text.begins_with("No orders counted yet"),
		"'no data' says why in its tooltip (%s)" % no_data.tooltip_text
	)
	f.close_league()


## Every label that names a model, on both pages, is a badge (hud_style.badge); nothing else on the
## street page says a model's name.
func _unbadged_models() -> Array[String]:
	var names: Array[String] = []
	for m: Dictionary in D.MAYORS:
		names.append(ModelLedger.short_name(str(m["model"])).to_lower())
	for e: Dictionary in ModelLedger.roster():
		names.append(ModelLedger.short_name(str(e["model"])).to_lower())
	var out: Array[String] = []
	var stack: Array[Node] = [f.league]
	var badges := 0
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if not n is Label:
			continue
		var l := n as Label
		if l.has_meta(S.BADGE_META):
			badges += 1
			continue
		var low := l.text.to_lower()
		for nm in names:
			if low.contains(nm):
				out.append(l.text)
		if S.branded(l.text):
			out.append(l.text)
	if badges == 0:
		out.append("(no badge at all)")
	return out


## Tab flips to Services & minds and back; the page lists the minds that are not mayors.
func _check_pages() -> void:
	# _check_fit closed the league; Tab only flips an open one.
	K.check(fails, f.open_league(), "fixture: the league opens for the page checks")
	var page_b: Control = f.league.get("_page_b")
	var page_a: Control = f.league.get("_page_a")
	K.check(
		fails, f.league.page == 0 and not page_b.visible, "the league opens on the mayors' page"
	)
	await process_frame
	await process_frame
	var panel: Control = f.league.get_node("Panel")
	var top_a := panel.global_position.y
	var height_a := panel.size.y
	_send(K.key_event(KEY_TAB))
	await process_frame
	await process_frame
	var jump := absf(panel.global_position.y - top_a)
	K.check(
		fails,
		jump < 1.5 and absf(panel.size.y - height_a) < 1.5,
		(
			"flipping the page keeps the panel where it was (top %d -> %d, height %d -> %d)"
			% [int(top_a), int(panel.global_position.y), int(height_a), int(panel.size.y)]
		)
	)
	var title: Label = f.league.get("_title")
	var flipped: bool = f.league.page == 1 and page_b.visible and not page_a.visible
	K.check(fails, flipped and title.text == "Services & minds", "Tab shows Services & minds")
	var minds := f.league.minds_lines()
	var gazette := ""
	var speaker := ""
	var idle := 0
	for l: String in minds:
		gazette = l if l.contains("GridFall Gazette") else gazette
		speaker = l if l.contains("Council Speaker") else speaker
		idle += int(l.ends_with("idle"))
	var g_want := "MiMo-V2.6-Flash GridFall Gazette 1 · 1 · 1 · 0 · 0 · 0 · 5.0 s · good"
	K.check(fails, gazette == g_want, "the Gazette's model: calls, live, ... health (%s)" % gazette)
	var s_want := "gpt-6-luna Council Speaker 2 · 2 · 0 · 2 · 0 · 2 · - · down"
	K.check(fails, speaker == s_want, "a failing service reads down (%s)" % speaker)
	var listed_msg := "every model the city uses is listed, idle too (%d rows, %d idle)"
	K.check(fails, minds.size() >= 9 and idle >= 5, listed_msg % [minds.size(), idle])
	var branded := _branded()
	K.check(
		fails, branded.is_empty(), "no brand word on the second page either (%s)" % str(branded)
	)
	var loose := _unbadged_models()
	K.check(
		fails,
		loose.is_empty(),
		"a model's name appears on the street pages only as a badge (%s)" % str(loose)
	)
	var minds_clipped := _clipped(f.league.get("_minds_table")).filter(
		func(c: String) -> bool: return not c.contains("·")
	)
	K.check(
		fails,
		minds_clipped.is_empty(),
		"no number or word on page 2 is cut (%s)" % str(minds_clipped)
	)
	var hint: Label = f.league.get("_flip_hint")
	K.check(fails, hint.text == "Mayors' league", "the footer says where Tab goes back to")
	_send(K.key_event(KEY_TAB, true))
	K.check(fails, f.league.page == 1, "a held Tab does not flip again")
	_send(K.key_event(KEY_TAB))
	K.check(fails, f.league.page == 0 and page_a.visible, "Tab again goes back")
	_send(K.key_event(KEY_TAB))
	K.check(fails, f.league.page == 1, "fixture: closing on Services & minds")
	f.close_league()
	f.open_league()
	K.check(fails, f.league.page == 0 and page_a.visible, "reopened on the mayors' table")
	f.close_league()


## Flag off: the league still lists the five (Orders is the sim's own count), the ledger is empty.
func _check_flag_off() -> void:
	# The ledger still holds what _feed counted (as one loaded from an older save would): with the
	# flag off none of it may show as a speed or a light.
	FeatureFlags.set_override("model_ledger", false)
	f.open_league()
	var dots: PackedStringArray = f.league.health_dots()
	var calm := dots.size() == D.MAYORS.size()
	for d in dots:
		calm = calm and d == "idle"
	var speeds := true
	for l: String in f.league.table_lines():
		speeds = speeds and l.contains(" · - · ")
	K.check(
		fails, calm and speeds, "flag off: Speed reads - and the lights read idle (%s)" % str(dots)
	)
	f.close_league()
	ctx.brain.ledger.clear()
	f.open_league()
	var five: bool = f.league.table_lines().size() == D.MAYORS.size()
	K.check(fails, five, "flag off: the league still lists the five")
	var sim_orders := false
	for l: String in f.league.table_lines():
		sim_orders = sim_orders or l.contains("50%")
	K.check(fails, sim_orders, "flag off: Orders falls back to the sim's own count (50%)")
	f.close_league()
	FeatureFlags.set_override("model_ledger", true)
	ctx.brain.ledger.clear()
