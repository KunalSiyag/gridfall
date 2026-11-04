extends SceneTree
## The council card in every source (live, replay, offline): the headline, the votes line and the
## quote never contradict each other. A table over replay days 1-12 and six floors of proposals
## (unanimous, 3-2, lost, waiting, mixed, already in force) checks that a recorded Speaker's words
## are kept only when what it enacted and repealed really happened and no proposal was ruled
## against votes it never saw, and are otherwise set aside; the vote line never sets "Rejected"
## beside five yes. A proposal that stays deferred is recorded once, is no override while a mayor
## has still to vote, and is no news on the street or in the Gazette a second time. Flipping a vote
## drops the reason given for the old one. Headless, offline, fake transports only.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const NET := preload("res://tools/tests/support/scripted_net.gd")
const FIX := preload("res://tools/tests/support/council_fixture.gd")
const CL := preload("res://scripts/ai/council_log.gd")
const W := preload("res://scripts/fp/activity/activity_words.gd")
const MC := preload("res://scripts/ai/mayor_context.gd")
const CACHE := preload("res://scripts/ai/gmi_cache.gd")
const TOKEN := "FP_COUNCIL_REPLAY_TEST"
## Floors of proposals: {key: [proposer seat, yes, no]}; "active" ordinances start in force.
const FLOORS := {
	"unanimous": {"floor": {"recycling": [0, 5, 0]}},
	"three-two": {"floor": {"green_energy_subsidy": [1, 3, 2], "clean_air_act": [2, 4, 1]}},
	"lost": {"floor": {"public_transit": [3, 2, 3], "curfew": [4, 1, 3]}},
	"waiting": {"floor": {"recycling": [0, 1, 0], "curfew": [4, 3, 0]}},
	"mixed":
	{
		"floor":
		{
			"recycling": [0, 5, 0],
			"green_energy_subsidy": [1, 3, 2],
			"clean_air_act": [2, 2, 2],
			"curfew": [4, 3, 0]
		}
	},
	"in force":
	{
		"floor": {"recycling": [0, 5, 0], "curfew": [4, 2, 3]},
		"active": ["recycling", "public_transit"]
	},
}

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	await _check_replay_table()
	await _check_offline_table()
	await _check_known_cases()
	await _check_live_card()
	_check_limits()
	await _check_deferral_once()
	await _check_vote_flip()
	K.finish(self, TOKEN, fails)


# ------------------------------------------------------------------ replay and offline table


## Runs the council on day with the floor and returns its ruling.
func _rule(w: Dictionary, floor: Dictionary, day: int) -> Dictionary:
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	sim.ordinances.clear()
	for key: Variant in floor.get("active", []):
		sim.ordinances[str(key)] = 1
	brain.council_history.clear()
	brain.proposals = {}
	for key: String in (floor["floor"] as Dictionary).keys():
		var p: Array = floor["floor"][key]
		brain.proposals[key] = FIX.prop(int(p[0]), FIX.votes_of(int(p[1]), int(p[2])))
	var got: Array[Dictionary] = []
	var keep := func(r: Dictionary) -> void: got.append(r)
	brain.council_ruled.connect(keep)
	await brain._run_council(day)
	brain.council_ruled.disconnect(keep)
	return got[0] if not got.is_empty() else {}


## The recorded Speaker's reply for day, or {}.
func _recorded(client: GmiClient, day: int) -> Dictionary:
	var entries: Variant = client.replay_cache.get("council|speaker", [])
	return CACHE.nearest(entries as Array, day, true) if typeof(entries) == TYPE_ARRAY else {}


func _check_replay_table() -> void:
	var w := FIX.world(get_root())
	var client: GmiClient = w["client"]
	check(not client.replay_cache.is_empty(), "fixture: the recorded run is loaded")
	var sources := {}
	var kept := 0
	var set_aside := 0
	for name: String in FLOORS.keys():
		for day in range(1, 13):
			var r := await _rule(w, FLOORS[name], day)
			check(not r.is_empty(), "%s, day %d: the council ruled" % [name, day])
			if r.is_empty():
				continue
			var src := str(r["source"])
			sources[src] = true
			var rec := _recorded(client, day)
			var said := str(r["statement"])
			var recorded_said := D.debrand(str(rec.get("statement", ""))).left(240)
			if said == recorded_said and not rec.is_empty():
				kept += 1
			else:
				set_aside += 1
			_assert_card("%s day %d" % [name, day], r, rec, src)
	check(
		sources.has("cache") and sources.has("heuristic"),
		(
			"the table covers the recording and, past its last day, the offline planner (%s)"
			% str(sources.keys())
		)
	)
	check(
		kept > 0 and set_aside > 0,
		(
			"some recorded statements fit the votes and are kept (%d), the rest are set aside (%d)"
			% [kept, set_aside]
		)
	)
	FIX.free_world(w)


## No recording at all: the offline planner's card is as consistent.
func _check_offline_table() -> void:
	var w := FIX.world(get_root())
	(w["client"] as GmiClient).replay_cache = {}
	for name: String in FLOORS.keys():
		var r := await _rule(w, FLOORS[name], 5)
		check(str(r.get("source", "")) == "heuristic", "%s offline: the planner ruled" % name)
		_assert_card("%s offline" % name, r, {}, "heuristic")
	FIX.free_world(w)


## What a viewer reads on the street card for a ruling must agree with itself. rec is the recorded
## Speaker's reply ({} offline).
func _assert_card(label: String, r: Dictionary, rec: Dictionary, src: String) -> void:
	var head := W.council_words(r)
	var votes := W.council_votes(r)
	var said := str(r["statement"])
	check(
		not head.contains("override") and not votes.begins_with("The Speaker went against"),
		"%s: a recorded or offline Speaker never reads as defiant (%s)" % [label, head]
	)
	var enacted: Array = r["enacted"]
	var set_of := func(a: Variant) -> Array:
		var out: Array = []
		for k: Variant in a as Array:
			out.append(str(k))
		out.sort()
		return out
	for t: Variant in r["tally"]:
		var e: Dictionary = t
		var name := str(D.ORDINANCES[str(e["key"])]["label"])
		var yes := int(e["yes"])
		if CL.quiet(e):
			check(
				not votes.contains(name + ": yes") and not head.contains("%s %d-" % [name, yes]),
				(
					"%s: %s is ruled against its votes, so no vote line and no count (%s | %s)"
					% [label, name, head, votes]
				)
			)
		elif votes.begins_with(name + ": yes"):
			var passed := str(e["outcome"]) == "enacted"
			check(
				passed == (yes >= CL.MAJORITY),
				"%s: the votes line (%s) agrees with %s" % [label, votes, str(e["outcome"])]
			)
	for key: Variant in enacted:
		var name := str(D.ORDINANCES[str(key)]["label"])
		check(
			head.contains("Passed " + name) or head.contains("more"),
			"%s: the headline says %s passed (%s)" % [label, name, head]
		)
	var fits := (
		not rec.is_empty()
		and set_of.call(rec.get("enact", [])) == set_of.call(r["enacted"])
		and set_of.call(rec.get("repeal", [])) == set_of.call(r["repealed"])
	)
	if src == "cache" and said == D.debrand(str(rec.get("statement", ""))).left(240):
		check(
			fits,
			"%s: the recorded words are kept only when they happened (%s)" % [label, said.left(40)]
		)
		for t: Variant in r["tally"]:
			check(
				not bool((t as Dictionary)["against"]),
				"%s: and no proposal went against its votes" % label
			)
	else:
		check(
			said == str(CL.SET_ASIDE.get(src, said)),
			"%s: else the words are set aside (%s)" % [label, said.left(50)]
		)
	for key: Variant in r["rejected"]:
		var word := str(D.ORDINANCES[str(key)]["label"]).get_slice(" ", 0).to_lower()
		var low := said.to_lower()
		check(
			not (low.contains(word) and (low.contains(" passes") or low.contains("approves"))),
			"%s: the quote does not say a rejected proposal passes (%s)" % [label, said.left(60)]
		)


## The finding's own case and its mirror, spelled out.
func _check_known_cases() -> void:
	var w := FIX.world(get_root())
	var client: GmiClient = w["client"]
	var rec := _recorded(client, 11)
	check(
		(
			(rec["enact"] as Array) == ["recycling"]
			and str(rec["statement"]).begins_with("Recycling passes")
		),
		"fixture: day 11 of the recording passes Recycling and repeals Public Transit"
	)
	# Recycling is already in force, so the recorded pass cannot happen: card says what happened.
	var r := await _rule(w, {"floor": {"recycling": [0, 5, 0]}, "active": ["recycling"]}, 11)
	check(
		W.council_words(r) == "Rejected Recycling Program",
		"in force: the headline is the result, no count (%s)" % W.council_words(r)
	)
	check(W.council_votes(r).is_empty(), "in force: no votes line of five yes beside 'Rejected'")
	check(
		str(r["statement"]) == str(CL.SET_ASIDE["cache"]),
		"in force: the recorded 'Recycling passes' is set aside (%s)" % str(r["statement"])
	)
	# Everything the recording did happens: its words stand, the votes line agrees with them.
	r = await _rule(w, {"floor": {"recycling": [0, 5, 0]}, "active": ["public_transit"]}, 11)
	check(
		W.council_words(r) == "Passed Recycling Program 5-0 · Repealed Public Transit Network",
		"fits: passed with the count, and the repeal (%s)" % W.council_words(r)
	)
	check(
		(
			str(r["statement"]).begins_with("Recycling passes with unanimous support")
			and W.council_votes(r) == "Recycling Program: yes Ada, Viktor, Mei, Rosa, Duke"
		),
		"fits: the recorded words and the five yes agree (%s)" % W.council_votes(r)
	)
	# The orbit record names the replay and whose votes it shows.
	r = await _rule(w, {"floor": {"recycling": [0, 5, 0]}, "active": ["recycling"]}, 11)
	var row := (w["brain"] as CityBrain).council_history[-1]
	check(
		CL.quiet(row) and CL.verdict(row) == "rejected",
		"in force: the record reads 'rejected' with no count (%s)" % CL.verdict(row)
	)
	FIX.free_world(w)


# ------------------------------------------------------------------ live


## A live Speaker's words are kept; what it did against the count is flagged beside them.
func _check_live_card() -> void:
	var net := NET.new()
	net.name = "Net"
	net.live_enabled = true
	var w := FIX.world(get_root(), net)
	var brain: CityBrain = w["brain"]
	net.by_model[str(D.SUPPORT_AGENTS["council"]["model"])] = {
		"enact": ["curfew"], "repeal": [], "statement": "Curfew passes on the data."
	}
	var r := await _rule(w, {"floor": {"curfew": [4, 2, 3], "recycling": [0, 5, 0]}}, 9)
	check(
		str(r["source"]) == "live" and str(r["statement"]) == "Curfew passes on the data.",
		"live: the words are the model's"
	)
	check(
		W.council_words(r).begins_with("Passed Youth Curfew with 2 yes (override)"),
		"live: the headline says it went against the count (%s)" % W.council_words(r)
	)
	check(
		W.council_votes(r).begins_with(
			"The Speaker went against the vote. Youth Curfew: yes Ada, Viktor"
		),
		"live: and so does the votes line (%s)" % W.council_votes(r)
	)
	check(brain.council_history.size() == 2, "live: a record each")
	FIX.free_world(w)


# ------------------------------------------------------------------ limits pinned


func _check_limits() -> void:
	check(
		not CL.goes_against("deferred", 4, 4),
		"a deferral with 4 yes and a mayor still to vote is waiting"
	)
	check(
		CL.goes_against("deferred", 4, 5), "a deferral with 4 yes of 5 votes is against the count"
	)
	check(
		(
			CL.goes_against("deferred", 3)
			and CL.is_override("deferred", 3, "live", 5)
			and not CL.is_override("deferred", 3, "live", 3)
		),
		"three yes of five votes in is an override, three yes of three is not"
	)
	check(
		(
			CL.goes_against("rejected", 3, 4)
			and CL.goes_against("enacted", 2, 2)
			and not CL.goes_against("deferred", 2, 5)
		),
		"a rejection (four votes in) and an enactment with 2 yes still go against the count"
	)
	check(not CL.goes_against("enacted", 3, 3), "an enactment with 3 yes of 3 is the majority's")
	var saved := CL.restore(
		[
			{
				"day": 4,
				"key": "curfew",
				"outcome": "deferred",
				"source": "live",
				"votes": {"argon": "yes", "kimi": "yes", "qwen": "yes"}
			}
		]
	)
	check(
		not bool(saved[0]["override"]) and not bool(saved[0]["against"]),
		"a saved 3-vote deferral loads as waiting"
	)
	check(
		(
			(
				CL.feed_line({"key": "curfew", "outcome": "deferred", "yes": 4})
				== "The Speaker held back Youth Curfew despite 4 yes, over the count."
			)
			and (
				CL.feed_line({"key": "curfew", "outcome": "enacted", "yes": 2})
				== "The Speaker passed Youth Curfew with only 2 yes, over the count."
			)
			and (
				CL.feed_line({"key": "curfew", "outcome": "rejected", "yes": 3})
				== "The Speaker rejected Youth Curfew despite 3 yes, over the count."
			)
		),
		"the Gazette hears it as prose, without the board's capital label"
	)
	var tl := CL.tally(
		{"curfew": FIX.prop(4, FIX.votes_of(3, 2))},
		[],
		[],
		"live",
		[{"key": "curfew", "outcome": "deferred", "override": true}]
	)
	check(
		bool(tl[0]["repeat"]) and not bool(tl[0]["news"]),
		"a deferral already held against the count is a repeat and no news"
	)
	tl = CL.tally(
		{"curfew": FIX.prop(4, FIX.votes_of(3, 2))},
		[],
		[],
		"live",
		[{"key": "curfew", "outcome": "deferred", "override": false}]
	)
	check(
		bool(tl[0]["repeat"]) and bool(tl[0]["news"]),
		"but the one that just became an override is news"
	)
	tl = CL.tally(
		{"curfew": FIX.prop(4, FIX.votes_of(3, 2))},
		[],
		[],
		"live",
		[{"key": "curfew", "outcome": "rejected"}]
	)
	check(
		not bool(tl[0]["repeat"]) and bool(tl[0]["news"]),
		"a deferral after a rejection starts over"
	)


# ------------------------------------------------------------------ a stuck proposal


func _gazette_lines(brain: CityBrain) -> int:
	var n := 0
	for l in brain.day_feed:
		if l.contains("over the count"):
			n += 1
	return n


func _check_deferral_once() -> void:
	var net := NET.new()
	net.name = "Net"
	net.live_enabled = true
	var w := FIX.world(get_root(), net)
	var brain: CityBrain = w["brain"]
	var speaker := str(D.SUPPORT_AGENTS["council"]["model"])
	FeatureFlags.set_override("mayor_context_v2", true)
	net.by_model[speaker] = {"enact": [], "repeal": [], "statement": "Not yet."}
	brain.proposals = {
		"free_clinics": FIX.prop(2, FIX.votes_of(3, 2)),
		"trade_expo": FIX.prop(4, {"grok": "yes", "qwen": "no"}),
		"curfew": FIX.prop(4, FIX.votes_of(4, 0)),
	}
	var rulings: Array[Dictionary] = []
	brain.council_ruled.connect(func(r: Dictionary) -> void: rulings.append(r))
	for k in range(6):
		await brain._run_council(9 + 3 * k)
	check(
		brain.council_history.size() == 3,
		"six runs on three stuck proposals leave three records (%d)" % brain.council_history.size()
	)
	var fc := CL.last_for(brain.council_history, "free_clinics")
	check(
		(
			int(fc["day"]) == 24
			and bool(fc["override"])
			and CL.verdict(fc) == "OVERRIDE: deferred with 3 yes"
		),
		(
			"the one record is renewed with the latest day (%d) and is against the count"
			% int(fc["day"])
		)
	)
	var cur := CL.last_for(brain.council_history, "curfew")
	check(
		not bool(cur["override"]) and CL.verdict(cur) == "deferred 4-0",
		"4 yes with a mayor still to vote is no override (%s)" % CL.verdict(cur)
	)
	check(
		_gazette_lines(brain) == 1,
		"the Gazette hears of the free clinics once, not six times (%d)" % _gazette_lines(brain)
	)
	check(W.council_news(rulings[0]), "the first run is news on the street")
	var later := true
	for k in range(1, 6):
		later = later and not W.council_news(rulings[k])
	check(later, "the five repeats are not: no second card")
	check(
		W.council_words(rulings[2]) == "No ordinance changed",
		"and a card that is made reads so (%s)" % W.council_words(rulings[2])
	)
	# The fifth vote arrives: 4 yes of 5 votes in is now against the count, once.
	(brain.proposals["curfew"]["votes"] as Dictionary)["qwen"] = "no"
	await brain._run_council(27)
	cur = CL.last_for(brain.council_history, "curfew")
	check(
		(
			bool(cur["override"])
			and CL.verdict(cur) == "OVERRIDE: deferred with 4 yes"
			and brain.council_history.size() == 3
		),
		"the fifth vote makes it an override in the same record (%s)" % CL.verdict(cur)
	)
	check(
		W.council_news(rulings[-1]) and _gazette_lines(brain) == 2,
		"and that is news once (%d lines)" % _gazette_lines(brain)
	)
	await brain._run_council(30)
	check(not W.council_news(rulings[-1]) and _gazette_lines(brain) == 2, "and not again")
	# A real ruling is not pushed out of the history by the stuck ones.
	net.by_model[speaker] = {
		"enact": ["free_clinics"], "repeal": [], "statement": "Free clinics pass."
	}
	await brain._run_council(33)
	net.by_model[speaker] = {"enact": [], "repeal": [], "statement": "Not yet."}
	for k in range(25):
		await brain._run_council(36 + 3 * k)
	check(
		(
			str(CL.last_for(brain.council_history, "free_clinics")["outcome"]) == "enacted"
			and brain.council_history.size() <= 4
		),
		(
			"25 more runs on stuck proposals keep the enactment in the record (%d records)"
			% brain.council_history.size()
		)
	)
	FeatureFlags.set_override("mayor_context_v2", false)
	FIX.free_world(w)


# ------------------------------------------------------------------ vote flips


func _check_vote_flip() -> void:
	var net := NET.new()
	net.name = "Net"
	net.live_enabled = true
	var w := FIX.world(get_root(), net)
	var brain: CityBrain = w["brain"]
	FeatureFlags.set_override("mayor_context_v2", true)
	brain.proposals = {"curfew": FIX.prop(0, {"argon": "yes"})}
	var model := str(D.MAYORS[4]["model"])
	var vote := func(v: String, note: String) -> Dictionary:
		var reply := {
			"thought": "t",
			"public_post": "p",
			"mood": "m",
			"actions": [],
			"propose_ordinance": "",
			"votes": {"curfew": v}
		}
		if not note.is_empty():
			reply["vote_notes"] = {"curfew": note}
		return reply
	var notes := func() -> Dictionary: return brain.proposals["curfew"].get("notes", {})
	net.by_model[model] = vote.call("no", "kills nightlife")
	await brain._run_mayor(4, 6)
	check(notes.call().get("grok", "") == "kills nightlife", "a No comes with its reason")
	net.by_model[model] = vote.call("no", "")
	await brain._run_mayor(4, 7)
	check(
		notes.call().get("grok", "") == "kills nightlife",
		"the same vote again keeps the reason it stands on"
	)
	net.by_model[model] = vote.call("yes", "")
	await brain._run_mayor(4, 8)
	check(
		not notes.call().has("grok"),
		"a flipped vote drops the reason for the old one (%s)" % str(notes.call())
	)
	check(
		not brain._mayor_user_prompt(0, 8).contains("kills nightlife"),
		"and the other mayors are not shown it beside the new vote"
	)
	net.by_model[model] = vote.call("no", "too costly")
	await brain._run_mayor(4, 9)
	check(
		notes.call().get("grok", "") == "too costly",
		"a flip with a new reason stores that one (%s)" % str(notes.call())
	)
	MC.cast_vote(brain.proposals["curfew"], "grok", "yes")
	check(
		not notes.call().has("grok") and brain.proposals["curfew"]["votes"]["grok"] == "yes",
		"cast_vote flips the vote and drops the reason together"
	)
	MC.cast_vote(brain.proposals["curfew"], "kimi", "no")
	check(brain.proposals["curfew"]["votes"]["kimi"] == "no", "a first vote is just stored")
	FeatureFlags.set_override("mayor_context_v2", false)
	FIX.free_world(w)
