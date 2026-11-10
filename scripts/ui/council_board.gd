extends RefCounted
## The City Hall tab's vote board (orbit): each proposal on the floor as a five-seat row (mayor
## colour, Y / N / - for how that mayor voted, an asterisk after the proposer's name) with the tally
## and, for one the Speaker already looked at, what it did; then the record of the last rulings with
## a loud OVERRIDE where the Speaker went against the count; then the notes and requests the
## mayors left each other (only when a live model wrote some). Orbit text keeps model names, as
## the rest of the tab does. Returns BBCode for a RichTextLabel; model-written text is escaped.
## No nodes.

const D := preload("res://scripts/sim/sim_defs.gd")
const CouncilLog := preload("res://scripts/ai/council_log.gd")

const YES := "#5CFF9D"
const NO := "#FF7A6A"
const NONE := "#7C8A99"
const WARN := "#FFB800"
const DIM := "#9AB"
## Rulings the record lists.
const SHOWN := 6


## "Proposals on the floor" with a seat row each.
static func proposals_text(brain: CityBrain) -> String:
	var t := "\n[b]Proposals on the floor[/b]\n"
	if brain.proposals.is_empty():
		return t + "[i]none[/i]\n"
	t += "[color=%s]* marks the mayor who proposed it[/color]\n" % DIM
	for key: String in brain.proposals.keys():
		var pr: Dictionary = brain.proposals[key]
		var tl := CouncilLog.tally({key: pr}, [], [])[0]
		t += (
			"- %s by %s  [b]%s[/b]\n"
			% [
				D.ORDINANCES.get(key, {}).get("label", key),
				_esc(str(pr.get("by", "?"))),
				CouncilLog.score(tl),
			]
		)
		t += "   " + seat_row(tl, str(tl["by_id"])) + "\n"
		var last := CouncilLog.last_for(brain.council_history, key)
		if not last.is_empty() and str(last["outcome"]) == "deferred":
			t += (
				"   [color=%s]Speaker, day %d: %s%s[/color]\n"
				% [
					WARN if bool(last["override"]) else DIM,
					int(last["day"]),
					CouncilLog.verdict(last),
					_from(last)
				]
			)
		t += _reasons(tl)
	return t


## One row of five seats for a record or proposal ({"votes"}): "Ada* Y  Viktor Y  Mei -  Rosa N
## Duke -", each name in its mayor's colour (an asterisk after the proposer's: plain ASCII, web
## builds have no system font for a star glyph) and each vote in green, red or grey.
static func seat_row(e: Dictionary, proposer_id: String) -> String:
	var votes: Variant = e.get("votes", {})
	var seats: Array[String] = []
	for m: Dictionary in D.MAYORS:
		var id := str(m["id"])
		var v := "-"
		var col := NONE
		if typeof(votes) == TYPE_DICTIONARY and (votes as Dictionary).has(id):
			var yes := str((votes as Dictionary)[id]).to_lower().begins_with("y")
			v = "Y" if yes else "N"
			col = YES if yes else NO
		var mark := "*" if id == proposer_id else ""
		seats.append(
			(
				"[color=%s]%s%s[/color] [color=%s]%s[/color]"
				% [m["color"], CouncilLog.first_name(str(m["display"])), mark, col, v]
			)
		)
	return "  ".join(PackedStringArray(seats))


## The reason each NO (or YES) came with, one line (only when a live model gave any).
static func _reasons(e: Dictionary) -> String:
	var parts: Array[String] = []
	var notes: Dictionary = e.get("notes", {})
	for m: Dictionary in D.MAYORS:
		var id := str(m["id"])
		if notes.has(id):
			parts.append(
				"%s: %s" % [CouncilLog.first_name(str(m["display"])), _esc(str(notes[id]))]
			)
	return (
		""
		if parts.is_empty()
		else "   [color=%s][i]%s[/i][/color]\n" % [DIM, "; ".join(PackedStringArray(parts))]
	)


## "Council record": the newest SHOWN rulings, newest first, one headline and one seat row each.
static func history_text(brain: CityBrain) -> String:
	var hist := brain.council_history
	if hist.is_empty():
		return ""
	var t := "\n[b]Council record[/b]\n"
	for k in range(hist.size() - 1, maxi(hist.size() - 1 - SHOWN, -1), -1):
		var e: Dictionary = hist[k]
		var label: String = D.ORDINANCES.get(str(e["key"]), {}).get("label", str(e["key"]))
		var over := bool(e.get("override", false))
		t += (
			"Day %d  %s: [color=%s]%s[/color]%s\n"
			% [int(e["day"]), label, WARN if over else DIM, CouncilLog.verdict(e), _from(e)]
		)
		if str(e["outcome"]) != "repealed":
			t += "   " + seat_row(e, str(e.get("by_id", ""))) + "\n" + _reasons(e)
	return t


## "Notes between mayors": what the live models said to each other, newest first (empty until
## one did).
static func notes_text(brain: CityBrain) -> String:
	var rows: Array[Array] = []
	for to: Variant in brain.notes.keys():
		for n: Variant in brain.notes[to]:
			rows.append([int((n as Dictionary).get("day", 0)), str(to), n])
	if rows.is_empty():
		return ""
	rows.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
	var t := "\n[b]Notes between mayors[/b]\n"
	for r: Array in rows.slice(0, 6):
		var n: Dictionary = r[2]
		var from := D.mayor_display(D.mayor_index(str(n.get("from", ""))))
		var to := D.mayor_display(D.mayor_index(str(r[1])))
		var what := (
			("asks for $%d: " % int(n.get("amount", 0)))
			if str(n.get("kind", "")) == "request"
			else "says: "
		)
		t += (
			"Day %d  %s to %s %s[i]%s[/i]\n"
			% [int(r[0]), from, to, what, _esc(str(n.get("text", "")))]
		)
	return t


## " (replay)" or " (offline)" after a ruling that did not come from a live Speaker: a recorded or
## scripted Speaker does not read today's votes, so its rulings can look like overrides. A ruling
## that disagrees with the votes beside it says whose votes they are.
static func _from(e: Dictionary) -> String:
	var apart := ", today's votes" if CouncilLog.quiet(e) else ""
	match str(e.get("source", "")):
		"cache":
			return " [color=%s](replay%s)[/color]" % [NONE, apart]
		"heuristic":
			return " [color=%s](offline%s)[/color]" % [NONE, apart]
	return ""


static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")
