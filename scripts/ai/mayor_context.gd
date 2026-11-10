extends RefCounted
## Mayor context v2 (flag mayor_context_v2, default off until it has been tried live): what lets
## the five models answer EACH OTHER instead of five separate cities. A mayor's turn prompt gains
## the council's last ruling, the Grid Operator's order, the Chaos Director's strike, the league
## rank and the notes and requests other mayors left; its reply may carry vote_notes (why it voted
## so), message_to (one note a day to one mayor) and request (ask a mayor for money, answered by
## the existing grant action). Everything a model is asked to answer with is an id (argon ...):
## the prompt carries a table from the display names the other lines use to the ids, and a reply
## naming a mayor by display name or surname is understood too. With the flag off nothing here
## changes a prompt, a reply or a save. Offline planners and the replay cache never write notes, so
## notes exist only when a live model wrote them. Pure text and plain dictionaries: no nodes, no
## randomness, nothing new in the sim (a request is answered by the sim's own grant rule).

const D := preload("res://scripts/sim/sim_defs.gd")
const CouncilLog := preload("res://scripts/ai/council_log.gd")

const FLAG := "mayor_context_v2"
const VOTE_NOTE_CHARS := 60
const NOTE_CHARS := 120
const REASON_CHARS := 80
## The most a request may ask for; the asked mayor's own treasury still limits the grant.
const REQUEST_MAX := 3000
## Notes kept per mayor, the days an unseen note stays worth showing, and the days a note is kept.
const NOTES_PER_MAYOR := 4
const SHOW_DAYS := 3
const KEEP_DAYS := 8
## How long the last ruling, order and strike stay in a prompt (game days).
const COUNCIL_DAYS := 4
const OPERATOR_DAYS := 6
const CHAOS_DAYS := 5
## The league score of the street's table (ReporterDesk.CATEGORY): 25 points per category.
const CATEGORY := 25.0
const IDS := "argon|deepseek|kimi|qwen|grok"
# gdlint: disable=max-line-length
const EXTRA_RULES := (
	"""Mayor context v2 (optional reply fields: leave out what you do not need):
- vote_notes: one short reason (<=60 chars) for each vote you cast, so a NO is understood.
- message_to: ONE note a day (<=120 chars) to one other mayor, named by id; they read it on their next turn.
- request: ask another mayor for money (their id in "from"), with an amount and a reason; they may answer with a grant order.
- A grant is sensible when a mayor asks, the need is real and you can still keep a reserve, or when a neighbour's failing power, water or bankruptcy would hurt your own residents. Never grant more than your treasury holds. Mayors are always named by id ("""
	+ IDS
	+ """) in grant "to", message_to "mayor" and request "from".
"""
)
# gdlint: enable=max-line-length
const ROSTER_HEAD := (
	'MAYOR IDS (answer fields such as grant "to", message_to "mayor" and '
	+ 'request "from" take the id, not the name): '
)
const REQUEST_LINE := 'REQUEST FROM %s (day %d): asks you for $%d - "%s". '
const REQUEST_PAY := (
	'To agree, add {"type":"grant","to":"%s","amount":%d} to your actions; you hold $%d and a '
	+ "grant cannot be more than that."
)
const REQUEST_SHORT := (
	'You hold $%d, less than they ask: you could grant at most that, {"type":"grant","to":"%s",'
	+ '"amount":%d}, or decline.'
)
const REQUEST_BROKE := "You have no funds to give, so you can only decline."
const SCHEMA_OLD := '"votes":{"ordinance_key":"yes or no"}}'
const SCHEMA_NEW := (
	'"votes":{"ordinance_key":"yes or no"},"vote_notes":{"ordinance_key":"<=60 chars"},'
	+ '"message_to":{"mayor":"'
	+ IDS
	+ '","text":"<=120 chars"},'
	+ '"request":{"from":"'
	+ IDS
	+ '","amount":N,"reason":"<=80 chars"}}'
)
## What must not survive in a note: line and paragraph breaks, tabs and invisible spaces.
const SPACES := [
	"\n",
	"\r",
	"\t",
	"\u000b",
	"\u000c",
	"\u0085",
	"\u2028",
	"\u2029",
	"\u200b",
	"\u200c",
	"\u200d",
	"\u2060",
	"\ufeff"
]
const ORDINALS := ["1st", "2nd", "3rd", "4th", "5th"]

static var _id_words: RegEx = null


static func enabled() -> bool:
	return FeatureFlags.enabled(FLAG, false)


## The system prompt with the optional fields and the grant guidance (unchanged with the flag off).
static func extend_system(text: String) -> String:
	if not enabled():
		return text
	var marker := "\nReply with ONLY this JSON object"
	return text.replace(marker, "\n" + EXTRA_RULES.strip_edges() + marker).replace(
		SCHEMA_OLD, SCHEMA_NEW
	)


# ------------------------------------------------------------------ names and ids


## The id (argon ...) of the mayor a model named by id, display name ("Viktor Han"), first name,
## surname or brand, with or without "Mayor"; "" when it names none.
static func mayor_id(v: Variant) -> String:
	if typeof(v) != TYPE_STRING and typeof(v) != TYPE_STRING_NAME:
		return ""
	var t := str(v).strip_edges().to_lower()
	if t.begins_with("mayor "):
		t = t.trim_prefix("mayor ").strip_edges()
	if t.is_empty():
		return ""
	for m: Dictionary in D.MAYORS:
		var display := str(m["display"]).to_lower()
		var names := [
			str(m["id"]),
			display,
			str(m["name"]).to_lower(),
			display.get_slice(" ", 0),
			display.get_slice(" ", 1)
		]
		if t in names:
			return str(m["id"])
	return ""


## The display name of mayor id ("" for an unknown id).
static func display_of(mayor: String) -> String:
	return D.mayor_display(D.mayor_index(mayor))


## Free text a model wrote, safe to show and to feed back into a prompt: no brand names (the
## display name stands in for a brand, whole-word ids included), one plain line (every kind of line
## break, tab and invisible space becomes a space, double quotes become single ones so the text
## cannot close the quotes the prompt wraps it in) and at most n characters, cut at a word.
static func clean_text(t: String, n: int) -> String:
	var s := D.debrand(t.strip_edges())
	for ch: String in SPACES:
		s = s.replace(ch, " ")
	s = s.replace('"', "'")
	if _id_words == null:
		_id_words = RegEx.create_from_string("(?i)\\b(%s)\\b" % IDS)
	var out := ""
	var at := 0
	for hit in _id_words.search_all(s):
		out += s.substr(at, hit.get_start() - at) + display_of(hit.get_string().to_lower())
		at = hit.get_end()
	s = out + s.substr(at)
	return CouncilLog.cut(" ".join(s.split(" ", false)), n)


## An order with a grant's "to" turned into an id when the model wrote a name (flag on only).
static func fix_order(a: Dictionary) -> Dictionary:
	if not enabled() or str(a.get("type", "")) != "grant":
		return a
	var id := mayor_id(a.get("to"))
	if not id.is_empty():
		a["to"] = id
	return a


static func roster_line() -> String:
	var parts: Array[String] = []
	for m: Dictionary in D.MAYORS:
		parts.append("%s=%s" % [m["display"], m["id"]])
	return ROSTER_HEAD + ", ".join(PackedStringArray(parts))


# ------------------------------------------------------------------ the prompt lines


## The lines mayor mi's user prompt gains (empty with the flag off). Each appears only when the
## state it reports exists; all text about other agents is de-branded.
static func user_lines(brain: CityBrain, mi: int, day: int) -> Array[String]:
	var out: Array[String] = []
	if not enabled():
		return out
	out.append(roster_line())
	var rows: Array[String] = [
		_council_line(brain, day),
		_operator_line(brain, day),
		_chaos_line(brain, day),
		league_line(brain.sim, mi),
		_reasons_line(brain),
	]
	for r: String in rows:
		if not r.is_empty():
			out.append(r)
	out.append_array(note_lines(brain, mi, day))
	return out


static func _council_line(brain: CityBrain, day: int) -> String:
	var c: Dictionary = brain.last_council
	if c.is_empty() or day - int(c.get("day", -99)) > COUNCIL_DAYS:
		return ""
	var parts: Array[String] = []
	for e: Variant in _list(c.get("tally")):
		if typeof(e) == TYPE_DICTIONARY:
			parts.append("%s %s" % [_label((e as Dictionary).get("key")), CouncilLog.verdict(e)])
	if parts.is_empty():  # a ruling saved before the tally existed: read its lists
		for pair: Array in [["enacted", "passed"], ["rejected", "rejected"]]:
			for key: Variant in _list(c.get(pair[0])):
				parts.append("%s %s" % [_label(key), pair[1]])
	for key: Variant in _list(c.get("repealed")):
		parts.append("%s repealed" % _label(key))
	var words := "; ".join(PackedStringArray(parts))
	var said := clean_text(str(c.get("statement", "")), 220)
	if words.is_empty() and said.is_empty():
		return ""
	var line := (
		"COUNCIL RULED day %d: %s"
		% [int(c.get("day", day)), words if not words.is_empty() else "no ordinance changed"]
	)
	return line + ('. The Speaker said: "%s"' % said if not said.is_empty() else "")


static func _operator_line(brain: CityBrain, day: int) -> String:
	var o: Dictionary = brain.last_operator
	if o.is_empty() or day - int(o.get("day", -99)) > OPERATOR_DAYS:
		return ""
	var names: Array[String] = []
	for d: Variant in _list(o.get("priority")):
		names.append(D.mayor_display(int(d)))
	var line := "GRID OPERATOR (day %d): " % int(o.get("day", day))
	if not names.is_empty():
		line += (
			"power and water are shed from the LAST district first, order: "
			+ " > ".join(PackedStringArray(names))
			+ ". "
		)
	line += clean_text(str(o.get("note", "")), 180)
	var advice := clean_text(str(o.get("advice", "")), 160)
	return line + (" Advice: " + advice if not advice.is_empty() else "")


static func _chaos_line(brain: CityBrain, day: int) -> String:
	var c: Dictionary = brain.last_chaos
	if not bool(c.get("trigger", false)) or day - int(c.get("day", -99)) > CHAOS_DAYS:
		return ""
	var label := (
		str(D.DISASTERS.get(str(c.get("type", "")), {}).get("label", "an incident")).to_lower()
	)
	var line := "CHAOS DIRECTOR (day %d): set off %s" % [int(c.get("day", day)), label]
	var x := int(c.get("x", -1))
	var y := int(c.get("y", -1))
	if D.in_bounds(x, y):
		line += " at (%d,%d)" % [x, y]
		var holder := int(brain.sim.district[D.idx(x, y)])
		if holder >= 0 and holder < D.MAYORS.size():
			line += " in %s's district" % D.mayor_display(holder)
	var why := clean_text(str(c.get("reason", "")), 160)
	if why.is_empty():
		why = clean_text(str(c.get("narration", "")), 160)
	return line + (": " + why if not why.is_empty() else "")


static func _reasons_line(brain: CityBrain) -> String:
	var parts: Array[String] = []
	for key: String in brain.proposals.keys():
		var notes: Variant = brain.proposals[key].get("notes", {})
		if typeof(notes) != TYPE_DICTIONARY:
			continue
		var votes: Dictionary = brain.proposals[key].get("votes", {})
		for id: Variant in (notes as Dictionary).keys():
			parts.append(
				(
					'%s: %s (%s) "%s"'
					% [key, display_of(str(id)), str(votes.get(id, "?")), (notes as Dictionary)[id]]
				)
			)
	return (
		""
		if parts.is_empty()
		else "REASONS GIVEN FOR VOTES: " + "; ".join(PackedStringArray(parts))
	)


## v as an array, or an empty one when it is not.
static func _list(v: Variant) -> Array:
	return v as Array if typeof(v) == TYPE_ARRAY else []


static func _int(v: Variant, fallback: int, lo: int, hi: int) -> int:
	var n: Variant = ActionClean.number(v)
	return clampi(int(n) if n != null else fallback, lo, hi)


static func _label(key: Variant) -> String:
	return str(D.ORDINANCES.get(str(key), {}).get("label", str(key)))


# ------------------------------------------------------------------ the league


## The street's league (people, jobs, approval, funds against the best mayor), best first: rows of
## {"mi", "pop", "jobs", "funds", "approval", "score"}. The same rule as ReporterDesk.standings,
## kept here because scripts/ai may not import the street's code.
static func league_rows(sim: CitySim) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var best := {"pop": 1.0, "jobs": 1.0, "funds": 1.0}
	for mi in range(mini(D.MAYORS.size(), sim.mayors.size())):
		var m: Dictionary = sim.mayors[mi]
		var row := {
			"mi": mi,
			"pop": int(m.get("pop", 0)),
			"jobs": int(m.get("jobs", 0)),
			"funds": int(m.get("treasury", 0)),
			"approval": _approval(sim, mi, m)
		}
		for k: String in best.keys():
			best[k] = maxf(float(best[k]), float(row[k]))
		rows.append(row)
	for row: Dictionary in rows:
		var share := float(row["pop"]) / float(best["pop"]) + float(row["approval"]) / 10.0
		share += (
			float(row["jobs"]) / float(best["jobs"])
			+ maxf(float(row["funds"]), 0.0) / float(best["funds"])
		)
		row["score"] = roundi(CATEGORY * share)
	rows.sort_custom(_ahead)
	return rows


## What the district's residents think of the mayor (0-10), else its happiness scaled to 10.
static func _approval(sim: CitySim, mi: int, m: Dictionary) -> float:
	var mood: Dictionary = {}
	if sim.people != null and sim.people.is_active():
		mood = sim.people.district_mood(mi)
	if int(mood.get("residents", 0)) > 0:
		return clampf(float(mood.get("approval", 0.0)), 0.0, 10.0)
	return snappedf(clampf(float(m.get("happiness", 0.5)), 0.0, 1.0) * 10.0, 0.1)


## Higher score first, then the bigger district, then the lower seat.
static func _ahead(a: Dictionary, b: Dictionary) -> bool:
	var ka := [int(a["score"]), int(a["pop"]), -int(a["mi"])]
	var kb := [int(b["score"]), int(b["pop"]), -int(b["mi"])]
	return ka > kb


## "LEAGUE: you are 3rd of 5 (gaps to Duke Granger in 1st: people -120, ...)" for mayor mi; ""
## while nobody lives in the city yet. The leader sees the gap to the runner-up instead.
static func league_line(sim: CitySim, mi: int) -> String:
	var rows := league_rows(sim)
	if rows.is_empty() or int(rows[0]["pop"]) <= 0:
		return ""
	var rank := 0
	for k in range(rows.size()):
		if int(rows[k]["mi"]) == mi:
			rank = k
	var mine: Dictionary = rows[rank]
	var other: Dictionary = rows[1] if rank == 0 and rows.size() > 1 else rows[0]
	var other_rank := 1 if rank == 0 else 0
	var gaps := (
		"people %+d, jobs %+d, approval %+.1f, funds %s"
		% [
			int(mine["pop"]) - int(other["pop"]),
			int(mine["jobs"]) - int(other["jobs"]),
			float(mine["approval"]) - float(other["approval"]),
			_money(int(mine["funds"]) - int(other["funds"])),
		]
	)
	return (
		"LEAGUE: you are %s of %d (gaps to %s in %s: %s)"
		% [
			ORDINALS[mini(rank, ORDINALS.size() - 1)],
			rows.size(),
			D.mayor_display(int(other["mi"])),
			ORDINALS[other_rank],
			gaps,
		]
	)


static func _money(n: int) -> String:
	return "%s$%d" % ["-" if n < 0 else "+", absi(n)]


# ------------------------------------------------------------------ notes between mayors


## The notes and requests mayor mi has not read yet (and that are recent), as prompt lines.
static func note_lines(brain: CityBrain, mi: int, day: int) -> Array[String]:
	var out: Array[String] = []
	var me := str(D.MAYORS[mi]["id"])
	for n: Dictionary in unseen(brain, me, day):
		var who := display_of(str(n["from"]))
		if str(n["kind"]) == "request":
			var amount := int(n.get("amount", 0))
			var held := int(brain.sim.mayors[mi]["treasury"])
			var line := REQUEST_LINE % [who, int(n["day"]), amount, n["text"]]
			if held <= 0:
				line += REQUEST_BROKE
			elif held < amount:
				line += REQUEST_SHORT % [held, n["from"], held]
			else:
				line += REQUEST_PAY % [n["from"], amount, held]
			out.append(line)
		else:
			out.append('NOTE FROM %s (day %d): "%s"' % [who, int(n["day"]), n["text"]])
	return out


## Recipient's notes that were never shown and are at most SHOW_DAYS old, oldest first.
static func unseen(brain: CityBrain, mayor: String, day: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for n: Variant in _list(brain.notes.get(mayor)):
		if typeof(n) == TYPE_DICTIONARY and not bool((n as Dictionary).get("seen", false)):
			if day - int((n as Dictionary).get("day", -99)) <= SHOW_DAYS:
				out.append(n)
	return out


## Marks the notes a prompt showed (what unseen() returned when it was built) as read, but only
## when a model really answered that prompt (source "live"): if the call failed and the offline
## planner answered, nobody read them and they are shown again next turn. The builder itself
## changes nothing, so "Ask the five" can reuse it.
static func mark_seen(shown: Array[Dictionary], source: String) -> void:
	if not enabled() or source != "live":
		return
	for n: Dictionary in shown:
		n["seen"] = true


# ------------------------------------------------------------------ reading a reply


## What a live reply adds to the world: vote_notes, one message_to and one request. entry is the
## turn's log entry (its "votes" are the votes that counted); stored fields land on it so the HUDs
## and the street feed can show them. Nothing here touches the sim: a request is answered, if at
## all, by the asked mayor's own grant order on a later turn.
static func absorb(
	brain: CityBrain, mi: int, day: int, data: Dictionary, entry: Dictionary
) -> void:
	if not enabled():
		return
	var me := str(D.MAYORS[mi]["id"])
	_absorb_vote_notes(brain, me, data.get("vote_notes"), entry)
	var msg: Variant = data.get("message_to")
	if typeof(msg) == TYPE_DICTIONARY:
		var to := mayor_id((msg as Dictionary).get("mayor"))
		var text := clean_text(ActionClean.text_of((msg as Dictionary).get("text")), NOTE_CHARS)
		if _may_send(brain, me, to, text, "note", day):
			entry["message_to"] = {"to": to, "text": text}
			_deliver(brain, me, to, day, {"kind": "note", "text": text, "amount": 0})
	var req: Variant = data.get("request")
	if typeof(req) == TYPE_DICTIONARY:
		var asked := mayor_id((req as Dictionary).get("from"))
		var reason := clean_text(
			ActionClean.text_of((req as Dictionary).get("reason")), REASON_CHARS
		)
		var amount := _int((req as Dictionary).get("amount"), 0, 0, REQUEST_MAX)
		if amount > 0 and _may_send(brain, me, asked, reason, "request", day):
			entry["request"] = {"from": asked, "amount": amount, "reason": reason}
			_deliver(brain, me, asked, day, {"kind": "request", "text": reason, "amount": amount})


## Records a mayor's vote on a proposal. A mayor who flips his vote no longer stands behind the
## reason he gave for the old one: it is dropped here, and replaced when the same reply carries a
## new one (absorb runs after this).
static func cast_vote(proposal: Dictionary, me: String, vote: String) -> void:
	var votes: Dictionary = proposal["votes"]
	if votes.has(me) and str(votes[me]).begins_with("y") != vote.begins_with("y"):
		var notes: Variant = proposal.get("notes")
		if typeof(notes) == TYPE_DICTIONARY:
			(notes as Dictionary).erase(me)
	votes[me] = vote


static func _absorb_vote_notes(
	brain: CityBrain, me: String, raw: Variant, entry: Dictionary
) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var cast: Dictionary = entry.get("votes", {})
	var kept := {}
	for key: Variant in (raw as Dictionary).keys():
		var ks := str(key).to_lower()
		var text := clean_text(ActionClean.text_of((raw as Dictionary)[key]), VOTE_NOTE_CHARS)
		if cast.has(ks) and not text.is_empty():
			kept[ks] = text
			if brain.proposals.has(ks):
				var pr: Dictionary = brain.proposals[ks]
				if typeof(pr.get("notes")) != TYPE_DICTIONARY:
					pr["notes"] = {}
				(pr["notes"] as Dictionary)[me] = text
	if not kept.is_empty():
		entry["vote_notes"] = kept


## One note and one request per mayor per day, to another mayor, with some words.
static func _may_send(
	brain: CityBrain, me: String, to: String, text: String, kind: String, day: int
) -> bool:
	if to.is_empty() or to == me or text.is_empty():
		return false
	for list: Variant in brain.notes.values():
		for n: Variant in _list(list):
			if (
				typeof(n) == TYPE_DICTIONARY
				and str(n.get("from", "")) == me
				and str(n.get("kind", "")) == kind
				and int(n.get("day", -1)) == day
			):
				return false
	return true


static func _deliver(brain: CityBrain, me: String, to: String, day: int, note: Dictionary) -> void:
	var list: Array = brain.notes.get(to, []) if typeof(brain.notes.get(to)) == TYPE_ARRAY else []
	var n := {
		"from": me,
		"day": day,
		"kind": note["kind"],
		"text": note["text"],
		"amount": int(note["amount"]),
		"seen": false
	}
	list.append(n)
	while list.size() > NOTES_PER_MAYOR:
		list.pop_front()
	brain.notes[to] = list
	prune(brain.notes, day)
	var who := display_of(me)
	if str(n["kind"]) == "request":
		brain.day_feed.append(
			'%s asked %s for $%d: "%s"' % [who, display_of(to), int(n["amount"]), n["text"]]
		)
	else:
		brain.day_feed.append('%s told %s: "%s"' % [who, display_of(to), n["text"]])


## Drops notes older than KEEP_DAYS in place.
static func prune(notes: Dictionary, day: int) -> void:
	for key: Variant in notes.keys():
		var list: Variant = notes[key]
		if typeof(list) != TYPE_ARRAY:
			notes.erase(key)
			continue
		var kept: Array = []
		for n: Variant in list as Array:
			if (
				typeof(n) == TYPE_DICTIONARY
				and day - int((n as Dictionary).get("day", -99)) <= KEEP_DAYS
			):
				kept.append(n)
		notes[key] = kept
		if kept.is_empty():
			notes.erase(key)


## A saved notes dictionary made safe to load: known mayors only, at most NOTES_PER_MAYOR each,
## text de-branded and cut again (a save is a file anyone can edit).
static func restore(raw: Variant) -> Dictionary:
	var out := {}
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key: Variant in (raw as Dictionary).keys():
		var id := str(key)
		var list: Variant = (raw as Dictionary)[key]
		if D.mayor_index(id) < 0 or typeof(list) != TYPE_ARRAY:
			continue
		var kept: Array = []
		for n: Variant in (list as Array).slice(-NOTES_PER_MAYOR * 4):
			var from := (
				str((n as Dictionary).get("from", "")) if typeof(n) == TYPE_DICTIONARY else ""
			)
			if D.mayor_index(from) < 0 or from == id:
				continue
			var d := n as Dictionary
			var kind := "request" if str(d.get("kind", "")) == "request" else "note"
			(
				kept
				. append(
					{
						"from": from,
						"day": _int(d.get("day"), 0, 0, 1000000),
						"kind": kind,
						"text": clean_text(ActionClean.text_of(d.get("text")), NOTE_CHARS),
						"amount":
						_int(d.get("amount"), 0, 0, REQUEST_MAX) if kind == "request" else 0,
						"seen": ActionClean.truthy(d.get("seen")),
					}
				)
			)
		if not kept.is_empty():
			out[id] = kept.slice(-NOTES_PER_MAYOR)
	return out
