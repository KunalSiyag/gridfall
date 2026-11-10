extends RefCounted
## The council vote board's data: what the Speaker did with each proposal and how the five mayors
## had voted. CityBrain._run_council takes a tally of the proposals on the floor before the ruled
## ones leave it (tally), puts it on the ruling it emits and appends one record per proposal (and
## per repeal) to brain.council_history (record), the newest KEEP rulings. The Speaker is free to
## overrule the count (the system prompt lets it pass a proposal with only 2 yes, and nothing
## forces it to pass one with 3), so every record says whether the outcome matches the vote:
## "override" is true for an enactment with fewer than MAJORITY yes and for a proposal that
## stayed out (deferred or rejected) with MAJORITY yes or more. A proposal that is only deferred
## counts as held against the count once all five votes are in: with a mayor still to vote the
## Speaker may just be waiting. verdict() and score() put that in words for the HUDs ("passed 3-2",
## "OVERRIDE: passed with 2"). Only a LIVE Speaker is held to the count: a recorded (replay)
## Speaker did not read today's votes, so its ruling that disagrees with them is not an override
## (the record says "against" and the words drop the count). A proposal that stays deferred is
## recorded once and updated on later runs ("repeat"), and only a new outcome is news for the
## street and the Gazette. A recorded or scripted Speaker's statement is kept only when it fits
## what the council did (statement_for), so the headline, the count and the quote never disagree.
## Pure data and text, no nodes.

const D := preload("res://scripts/sim/sim_defs.gd")

## Rulings kept in the history and in a save.
const KEEP := 20
## Yes votes (of five) that make a majority.
const MAJORITY := 3
## Seats on the council: a proposal is only held back against the count once all of them voted.
const SEATS := 5
const OUTCOMES := ["enacted", "rejected", "deferred", "repealed"]
const PASSIVE := {
	"enacted": "passed", "rejected": "rejected", "deferred": "deferred", "repealed": "repealed"
}
## What a ruling says when the recorded or offline Speaker's own words do not fit what happened.
const SET_ASIDE := {
	"cache": "The recorded ruling did not fit today's votes, so it is set aside.",
	"heuristic": "The offline count could not carry out its own ruling, so the results stand.",
}


## The proposals on the floor with their votes, each classed by what the Speaker did: [{"key",
## "by" (display name), "by_id", "votes" {mayor id: "yes"|"no"}, "notes" {mayor id: reason}, "yes",
## "no", "outcome" (enacted|rejected|deferred), "against", "override", "repeat" (a deferral the
## history already holds), "news" (not a repeat, or it just became an override)}]. Call it before
## the ruled proposals are erased from proposals; history is brain.council_history, which tells a
## repeat from a first deferral.
static func tally(
	proposals: Dictionary,
	enacted: Array,
	rejected: Array,
	source: String = "live",
	history: Array = []
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key: String in proposals.keys():
		var pr: Dictionary = proposals[key]
		var votes := _votes_of(pr.get("votes"))
		var yes := votes.values().count("yes")
		var outcome := (
			"enacted" if enacted.has(key) else ("rejected" if rejected.has(key) else "deferred")
		)
		var override := is_override(outcome, yes, source, votes.size())
		var before := last_for(history, key)
		var repeat := outcome == "deferred" and str(before.get("outcome", "")) == "deferred"
		(
			out
			. append(
				{
					"key": key,
					"by": str(pr.get("by", "")),
					"by_id": _id_of_display(str(pr.get("by", ""))),
					"votes": votes,
					"notes": _notes_of(pr.get("notes")),
					"yes": yes,
					"no": votes.size() - yes,
					"outcome": outcome,
					"against": goes_against(outcome, yes, votes.size()),
					"override": override,
					"repeat": repeat,
					"news": not repeat or (override and not bool(before.get("override", false))),
				}
			)
		)
	return out


## Whether an outcome disagrees with a count of yes votes, whoever ruled. cast is how many mayors
## have voted: a proposal only held over (deferred) with a seat still to vote is waiting, not
## defying the count.
static func goes_against(outcome: String, yes: int, cast: int = SEATS) -> bool:
	if outcome == "enacted":
		return yes < MAJORITY
	if outcome == "deferred" and cast < SEATS:
		return false
	return outcome != "repealed" and yes >= MAJORITY


## Whether the Speaker went against the count: it disagrees AND the Speaker is a live model that
## read today's votes (source "live"); a replayed or scripted ruling is never an override.
static func is_override(
	outcome: String, yes: int, source: String = "live", cast: int = SEATS
) -> bool:
	return source == "live" and goes_against(outcome, yes, cast)


## Appends the ruling's records to brain.council_history (newest last, KEEP at most) and, with
## mayor context v2 on, tells the Gazette's feed when the Speaker went against the vote. A proposal
## that stays deferred keeps the one record it has (renewed with its latest votes, notes, day and
## words, as the newest) and the Gazette hears of a ruling against the count only when it is news.
static func record(brain: CityBrain, ruling: Dictionary) -> void:
	var hist: Array[Dictionary] = brain.council_history
	var day := int(ruling.get("day", 0))
	var base := {
		"day": day,
		"statement": str(ruling.get("statement", "")),
		"source": str(ruling.get("source", ""))
	}
	for t: Variant in ruling.get("tally", []):
		var e: Dictionary = (t as Dictionary).duplicate(true)
		e.merge(base)
		var repeat := bool(e.get("repeat", false))
		var news := bool(e.get("news", true))
		e.erase("repeat")
		e.erase("news")
		var at := _index_for(hist, str(e["key"])) if repeat else -1
		if at >= 0:
			hist.remove_at(at)  # renewed below as the newest, with its latest votes and day
		hist.append(e)
		if news and bool(e["override"]) and FeatureFlags.enabled("mayor_context_v2", false):
			brain.day_feed.append(feed_line(e))
	for key: Variant in ruling.get("repealed", []):
		var e := {
			"key": str(key),
			"by": "",
			"by_id": "",
			"votes": {},
			"notes": {},
			"yes": 0,
			"no": 0,
			"outcome": "repealed",
			"against": false,
			"override": false
		}
		e.merge(base)
		hist.append(e)
	while hist.size() > KEEP:
		hist.pop_front()


## The Gazette feed's sentence for a ruling against the count, in prose (the board's loud
## "OVERRIDE:" label stays on the HUDs).
static func feed_line(e: Dictionary) -> String:
	var what := _label(e.get("key"))
	var n := int(e.get("yes", 0))
	match str(e.get("outcome", "")):
		"enacted":
			return "The Speaker passed %s with only %d yes, over the count." % [what, n]
		"rejected":
			return "The Speaker rejected %s despite %d yes, over the count." % [what, n]
	return "The Speaker held back %s despite %d yes, over the count." % [what, n]


## What the council's statement says: the Speaker's own words when they fit what the council did,
## else (a recorded or offline Speaker only) a plain line that sets them aside. They fit when every
## ordinance the Speaker enacted or repealed (enact, repeal: its reply's lists) really changed, no
## proposal went against the count, and none held back was called "rejected" by the words but
## "deferred" by the result or the other way round. A live Speaker's words are always kept: they
## are the model's own and its disagreements are flagged as overrides.
static func statement_for(
	source: String,
	statement: String,
	enact: Variant,
	repeal: Variant,
	enacted: Array,
	repealed: Array,
	tally: Array
) -> String:
	if source == "live" or not SET_ASIDE.has(source):
		return statement
	var low := statement.to_lower()
	var fits := _same_keys(enact, enacted) and _same_keys(repeal, repealed)
	for t: Variant in tally:
		var e: Dictionary = t
		fits = fits and not bool(e.get("against", false))
		if str(e.get("outcome", "")) == "rejected" and low.contains("defer"):
			fits = false
		if str(e.get("outcome", "")) == "deferred" and low.contains("reject"):
			fits = false
	return statement if fits else str(SET_ASIDE[source])


static func _same_keys(listed: Variant, done: Array) -> bool:
	var a: Array[String] = []
	if typeof(listed) == TYPE_ARRAY:
		for k: Variant in listed as Array:
			if not a.has(str(k)):
				a.append(str(k))
	a.sort()
	var b: Array[String] = []
	for k: Variant in done:
		b.append(str(k))
	b.sort()
	return a == b


static func _index_for(hist: Array, key: String) -> int:
	for k in range(hist.size() - 1, -1, -1):
		if (
			typeof(hist[k]) == TYPE_DICTIONARY
			and str((hist[k] as Dictionary).get("key", "")) == key
		):
			return k
	return -1


## "3-2" (yes-no) for a record, "" for one with no votes (a repeal).
static func score(e: Dictionary) -> String:
	if int(e.get("yes", 0)) + int(e.get("no", 0)) == 0:
		return ""
	return "%d-%d" % [int(e.get("yes", 0)), int(e.get("no", 0))]


## What the Speaker did, against the count: "passed 3-2", "deferred 2-1", "OVERRIDE: passed with
## 2", "OVERRIDE: deferred with 4 yes", "repealed".
static func verdict(e: Variant) -> String:
	if typeof(e) != TYPE_DICTIONARY:
		return ""
	var d: Dictionary = e
	var word: String = PASSIVE.get(str(d.get("outcome", "")), "ruled")
	if not bool(d.get("override", false)):
		var s := score(d)
		return word if s.is_empty() or quiet(d) else "%s %s" % [word, s]
	if str(d.get("outcome", "")) == "enacted":
		return "OVERRIDE: passed with %d" % int(d.get("yes", 0))
	return "OVERRIDE: %s with %d yes" % [word, int(d.get("yes", 0))]


## Whether a record's ruling disagrees with its count without being an override (a replayed
## Speaker): its words leave the count out rather than set a ruling beside votes it never saw.
static func quiet(e: Dictionary) -> bool:
	return bool(e.get("against", false)) and not bool(e.get("override", false))


## Mayors' first names split by how they voted: {"yes": [..], "no": [..], "none": [..]} in seat
## order, for a record (or any dictionary with "votes").
static func seats(e: Dictionary) -> Dictionary:
	var out := {"yes": [], "no": [], "none": []}
	var votes := _votes_of(e.get("votes"))
	for m: Dictionary in D.MAYORS:
		var v: String = votes.get(str(m["id"]), "none")
		(out[v] as Array).append(first_name(str(m["display"])))
	return out


static func first_name(display: String) -> String:
	return display.get_slice(" ", 0)


## The newest record for a proposal key, or {}.
static func last_for(history: Array, key: String) -> Dictionary:
	var k := _index_for(history, key)
	return history[k] if k >= 0 else {}


## A saved history made safe to load: dictionaries only, known outcomes, votes and notes cut to
## the five mayors, text de-branded and cut again, the newest KEEP.
static func restore(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for r: Variant in (raw as Array).slice(-KEEP * 4):
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = r
		var votes := _votes_of(d.get("votes"))
		var yes := votes.values().count("yes")
		var outcome := str(d.get("outcome", ""))
		var source := str(d.get("source", "")).left(12)
		if not OUTCOMES.has(outcome):
			continue
		(
			out
			. append(
				{
					"day":
					maxi(
						0,
						int(
							(
								ActionClean.number(d.get("day"))
								if ActionClean.number(d.get("day")) != null
								else 0
							)
						)
					),
					"key": str(d.get("key", "")).left(40),
					"by": D.debrand(str(d.get("by", ""))).left(40),
					"by_id":
					str(d.get("by_id", "")) if D.mayor_index(str(d.get("by_id", ""))) >= 0 else "",
					"votes": votes,
					"notes": _notes_of(d.get("notes")),
					"yes": yes,
					"no": votes.size() - yes,
					"outcome": outcome,
					"against": goes_against(outcome, yes, votes.size()),
					"override": is_override(outcome, yes, source, votes.size()),
					"statement": D.debrand(str(d.get("statement", ""))).left(240),
					"source": source,
				}
			)
		)
	return out.slice(-KEEP)


## Votes keyed by mayor id with "yes" or "no" for values (anything starting with y is yes, the
## rule the HUD and the council always used); unknown keys dropped.
static func _votes_of(raw: Variant) -> Dictionary:
	var out := {}
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for m: Dictionary in D.MAYORS:
		var id := str(m["id"])
		if (raw as Dictionary).has(id):
			out[id] = "yes" if str((raw as Dictionary)[id]).to_lower().begins_with("y") else "no"
	return out


static func _notes_of(raw: Variant) -> Dictionary:
	var out := {}
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for m: Dictionary in D.MAYORS:
		var id := str(m["id"])
		if (raw as Dictionary).has(id):
			var t := cut(
				D.debrand(ActionClean.text_of((raw as Dictionary)[id])).replace("\n", " "), 60
			)
			if not t.is_empty():
				out[id] = t
	return out


## t cut to at most n characters at a word boundary, with "..." where something was left out (plain
## dots: web builds have no system fonts, so a missing glyph would show as a box).
static func cut(t: String, n: int) -> String:
	var s := t.strip_edges()
	if s.length() <= n:
		return s
	var head := s.left(n - 3)
	var sp := head.rfind(" ")
	if sp >= (n - 3) / 2 and s[n - 3] != " ":
		head = head.left(sp)
	return head.rstrip(" ,.;:-") + "..."


static func _label(key: Variant) -> String:
	return str(D.ORDINANCES.get(str(key), {}).get("label", str(key)))


static func _id_of_display(display: String) -> String:
	for m: Dictionary in D.MAYORS:
		if str(m["display"]) == display:
			return str(m["id"])
	return ""
