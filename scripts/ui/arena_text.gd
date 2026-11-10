extends RefCounted
## The orbit view's Arena tab as BBCode text: a block per mayor (health light, the person's name
## with the model as the sub-line, turns by where the answer came from, time to answer, accepted
## orders, repairs, tokens and a bar of what the mayor orders), then a line per service. Rows are
## ModelLedger.mayor_rows() and services(). The orbit view keeps the model names (the model is the
## point of the demo; see fp_orbit_names_test), but still leads with the person's name.
##
## Honest labels: "time to answer" includes retries and waiting behind other calls, a mayor answers
## once a game day so its figures rest on a few calls and show their count, and a replayed or
## scripted turn is shown as that, never as a speed.
##
## Glyphs: the web build's HUD font has only Latin text (no system fallback there), so a light or a
## bar made of U+25CF or U+2588 shows as a box with a hex code. Lights and bars are therefore
## coloured background spans over plain "#" characters of the same colour: solid blocks where
## bgcolor is drawn, still a visible mark where it is not. Every character the tab prints is ASCII
## or U+00B7 (the middle dot), which ai_arena_test asserts.

const HEALTH_COLORS := {
	"green": "#5CFF9D",
	"amber": "#FFD27F",
	"red": "#FF7A6A",
	"grey": "#8A97A8",
	"scripted": "#8A97A8",
	"idle": "#8A97A8",
}
const HEALTH_WORDS := {
	"green": "answering live",
	"amber": "shaky",
	"red": "failing",
	"grey": "replay only",
	"scripted": "scripted only",
	"idle": "not called yet",
}
const DIM := "#9AB"
## Colours of the order-type segments of the mix bar, most frequent first.
const MIX_COLORS := ["#FFB800", "#00F0FF", "#B44CFF", "#10E88A", "#FF2E54", "#7FD1FF"]
const CAVEAT := (
	"[color=%s]Time to answer includes retries and waiting behind other calls: it is how long"
	+ " the city waited, not how fast a model is.[/color]\n\n"
)
const NO_LIVE := (
	"[i][color=%s]No live answer yet: replayed and scripted turns are shown as such. Orders of"
	+ " replayed turns are counted, the scripted planner's are not.[/color][/i]\n\n"
)
const TURNS := (
	"   turns: [color=#5CFF9D]live %d[/color] · [color=#FFD27F]replay %d[/color]"
	+ " · [color=#FF8A7A]fallback %d[/color] · offline %d\n"
)
## Characters per bar segment unit (a "#" is narrow): the whole bar is MIX_WIDTH * MIX_CELL wide.
## The tab is 384 px wide and a "#" about 8 px: 24 of them leave the bar on one line.
const MIX_CELL := 1
const MIX_WIDTH := 24
const MIX_LISTED := 6


## The whole tab for ledger (null: a line saying there is none).
static func text(ledger: ModelLedger) -> String:
	if ledger == null or not ModelLedger.enabled():
		return "[i]The model ledger is switched off (flag model_ledger).[/i]"
	var t := "[b]Arena[/b]  [color=%s]who answers, how fast, how well[/color]\n" % DIM
	t += CAVEAT % DIM
	var mayors := ledger.mayor_rows()
	var live_any := false
	for r: Dictionary in mayors:
		live_any = live_any or int(r["live_ok"]) + int(r["live_fail"]) > 0
		t += mayor_block(r) + "\n"
	if not live_any:
		t += NO_LIVE % DIM
	t += "[b]Services and minds[/b]\n"
	var services := ledger.services()
	if services.is_empty():
		t += "[i]Nothing has been asked of them yet.[/i]\n"
	for r: Dictionary in services:
		t += service_line(r) + "\n"
	return t


## One mayor's block (a few lines).
static func mayor_block(r: Dictionary) -> String:
	var col := str(r["color"])
	var t := (
		"%s [b][color=%s]%s[/color][/b]  [color=%s]%s · %s[/color]\n"
		% [
			light(str(r["health"])),
			col,
			esc(str(r["who"])),
			DIM,
			esc(str(r["model"])),
			esc(str(r["label"]))
		]
	)
	t += (
		TURNS
		% [
			int(r["turns_live"]),
			int(r["turns_replay"]),
			int(r["turns_fallback"]),
			int(r["turns_offline"])
		]
	)
	t += "   %s\n" % health_line(str(r["health"]))
	t += "   time to answer: %s\n" % esc(answer_words(r, true))
	t += "   orders accepted: %s · repairs: %s\n" % [accept_words(r), repair_words(r)]
	t += "   tokens: %s%s\n" % [token_words(r), error_words(r)]
	t += "   %s\n" % mix_line(r.get("mix", {}))
	return t


## One service's lines: the light, the model and its jobs; the light's word (with the time to answer
## when there was a live one); then how the calls went, in two short lines. Every line fits the
## tab's 384 px (about 55 characters): one line of counts wrapped with "scripted 0" alone.
static func service_line(r: Dictionary) -> String:
	var t := (
		"%s [b]%s[/b] [color=%s]%s[/color]\n"
		% [light(str(r["health"])), esc(str(r["label"])), DIM, esc(str(r["mix"]))]
	)
	var word := health_line(str(r["health"]))
	if int(r.get("n_live", 0)) > 0:
		word += " · %s" % esc(answer_words(r, false))
	t += "   %s\n" % word
	t += (
		"   calls %d · live %d · failed %d\n   replay %d · scripted %d\n"
		% [
			int(r["calls"]),
			int(r["live_ok"]),
			int(r["live_fail"]),
			int(r["replay"]),
			int(r.get("fallback", 0)) + int(r.get("offline", 0))
		]
	)
	return t


## A health light: a coloured block (see the glyph note at the top).
static func light(health: String) -> String:
	return block(str(HEALTH_COLORS.get(health, HEALTH_COLORS["idle"])), 2)


## "answering live", "shaky"...: the light's word.
static func health_word(health: String) -> String:
	return str(HEALTH_WORDS.get(health, HEALTH_WORDS["idle"]))


## The light's word in its colour, as a line under a name.
static func health_line(health: String) -> String:
	var col: String = HEALTH_COLORS.get(health, HEALTH_COLORS["idle"])
	return "[color=%s]%s[/color]" % [col, health_word(health)]


## n characters of colour col: a background span over "#" of the same colour.
static func block(col: String, n: int) -> String:
	return "[bgcolor=%s][color=%s]%s[/color][/bgcolor]" % [col, col, "#".repeat(n)]


## The time to answer in words. A mayor (own: true) answers rarely: below ModelLedger.P95_MIN_CALLS
## live answers it shows the last, the mean and how many, never a percentile.
static func answer_words(r: Dictionary, own: bool) -> String:
	var n := int(r.get("n_live", 0))
	if n == 0:
		if own and int(r.get("turns_replay", 0)) + int(r.get("replay", 0)) > 0:
			return "replay (no live answer to time)"
		return "-"
	var last := ModelLedger.seconds_text(int(r["last_ms"]))
	if own and int(r["p95_ms"]) < 0:
		return "last %s · mean %s · n %d" % [last, ModelLedger.seconds_text(int(r["mean_ms"])), n]
	var s := "p50 %s" % ModelLedger.seconds_text(int(r["p50_ms"]))
	if int(r["p95_ms"]) >= 0:
		s += " · p95 %s" % ModelLedger.seconds_text(int(r["p95_ms"]))
	return "%s · n %d" % [s, n]


## "87% (46 of 53)" or "no data yet" before an order (the count starts with the ledger, so a save
## from before it has none until new turns land).
static func accept_words(r: Dictionary) -> String:
	var pct := int(r.get("accept_pct", -1))
	if pct < 0:
		return "no data yet"
	var total := int(r["orders_ok"]) + int(r["orders_rejected"])
	return "%d%% (%d of %d)" % [pct, int(r["orders_ok"]), total]


## "20% (1 of 5)" of live answers that needed a repair, or "-".
static func repair_words(r: Dictionary) -> String:
	var live := int(r.get("live_ok", 0))
	if live <= 0:
		return "-"
	return (
		"%d%% (%d of %d)"
		% [roundi(100.0 * float(r["repairs"]) / float(live)), int(r["repairs"]), live]
	)


## "5.2k in / 1.1k out", or "-" when no answer reported usage.
static func token_words(r: Dictionary) -> String:
	if int(r.get("token_calls", 0)) <= 0:
		return "-"
	return "%s in / %s out" % [kilo(int(r["tokens_in"])), kilo(int(r["tokens_out"]))]


## " · errors 429 x2, no JSON x1" (leading separator) or "".
static func error_words(r: Dictionary) -> String:
	var errors: Dictionary = r.get("errors", {})
	if errors.is_empty():
		return ""
	var parts: Array[String] = []
	for k: String in errors.keys():
		parts.append("%s x%d" % [k, int(errors[k])])
	parts.sort()
	return " · [color=#FF8A7A]errors %s[/color]" % esc(", ".join(PackedStringArray(parts)))


## The bar of what a mayor orders: segments of MIX_WIDTH cells by share, then the legend on the next
## line (a bar and its legend on one line wrapped mid-bar).
static func mix_line(mix: Dictionary) -> String:
	if mix.is_empty():
		return "[color=%s]orders: none yet[/color]" % DIM
	var kinds: Array = mix.keys()
	kinds.sort_custom(
		func(a: String, b: String) -> bool:
			if int(mix[a]) != int(mix[b]):
				return int(mix[a]) > int(mix[b])
			return a < b
	)
	var total := 0
	for k: String in kinds:
		total += int(mix[k])
	var bar := ""
	var legend: Array[String] = []
	var used := 0
	for i in range(mini(kinds.size(), MIX_LISTED)):
		var k: String = kinds[i]
		var col: String = MIX_COLORS[i % MIX_COLORS.size()]
		var want := roundi(float(MIX_WIDTH) * float(int(mix[k])) / float(total))
		var blocks := clampi(maxi(want, 1), 1, MIX_WIDTH - used)
		used += blocks
		bar += block(col, blocks * MIX_CELL)
		legend.append("[color=%s]%s %d[/color]" % [col, esc(k), int(mix[k])])
	return "%s\n   %s" % [bar, " ".join(PackedStringArray(legend))]


## 1234 -> "1.2k"; below 1000 as is.
static func kilo(n: int) -> String:
	return "%d" % n if n < 1000 else "%.1fk" % (float(n) / 1000.0)


## BBCode-safe text.
static func esc(s: String) -> String:
	return s.replace("[", "[lb]")
