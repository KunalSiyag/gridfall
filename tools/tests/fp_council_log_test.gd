extends SceneTree
## The council vote board's data and text (CouncilLog, CouncilBoard, CityBrain._run_council).
## Scripted proposals and a held client (support/gated_client.gd, the offline planner's majority
## rule), a scripted Speaker (support/scripted_net.gd) and the offline and replay mayors give a
## history record per proposal with the tally, the outcome and whether the Speaker went against
## the count; the City Hall board shows the five seats and the Speaker line from it. Headless,
## offline, fake transports only.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const GATED := preload("res://tools/tests/support/gated_client.gd")
const NET := preload("res://tools/tests/support/scripted_net.gd")
const FIX := preload("res://tools/tests/support/council_fixture.gd")
const CL := preload("res://scripts/ai/council_log.gd")
const BOARD := preload("res://scripts/ui/council_board.gd")
const TOKEN := "FP_COUNCIL_LOG_TEST"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	_check_words()
	await _check_majority_rule()
	await _check_speaker_overrides()
	await _check_offline_splits()
	await _check_replay_votes()
	await _check_vote_notes()
	_check_bounds()
	_check_board_text()
	K.finish(self, TOKEN, fails)


func _world(client: GmiClient = null) -> Dictionary:
	return FIX.world(get_root(), client)


func _free(w: Dictionary) -> void:
	FIX.free_world(w)


## Whether a line of the brain's Gazette feed contains text.
func _feed_has(brain: CityBrain, text: String) -> bool:
	for l in brain.day_feed:
		if l.contains(text):
			return true
	return false


func _prop(by: int, votes: Dictionary) -> Dictionary:
	return FIX.prop(by, votes)


func _record(brain: CityBrain, key: String) -> Dictionary:
	return CL.last_for(brain.council_history, key)


# ------------------------------------------------------------------ words


func _check_words() -> void:
	check(
		CL.is_override("enacted", 2) and not CL.is_override("enacted", 3),
		"enacting with fewer than 3 yes goes against the vote"
	)
	check(
		(
			CL.is_override("deferred", 3)
			and CL.is_override("rejected", 4)
			and not CL.is_override("deferred", 2)
		),
		"holding a proposal back with 3 or more yes goes against the vote"
	)
	check(not CL.is_override("repealed", 0), "a repeal has no vote to go against")
	check(
		(
			not CL.is_override("enacted", 2, "cache")
			and not CL.is_override("rejected", 4, "cache")
			and not CL.is_override("deferred", 3, "heuristic")
			and CL.goes_against("rejected", 4)
		),
		"a replayed or scripted Speaker never overrides, though its ruling can disagree"
	)
	var quiet := {"yes": 4, "no": 1, "outcome": "rejected", "against": true, "override": false}
	check(
		CL.quiet(quiet) and CL.verdict(quiet) == "rejected",
		"a replayed ruling against the count reads without the count (%s)" % CL.verdict(quiet)
	)
	var cut := CL.cut("Mayor Granger blocks it; factories would close and jobs vanish", 60)
	check(
		cut == "Mayor Granger blocks it; factories would close and jobs..." and cut.length() <= 60,
		"a long reason is cut at a word with dots (%s)" % cut
	)
	check(
		(
			CL.cut("short", 60) == "short"
			and CL.cut("x".repeat(90), 60).length() == 60
			and CL.cut("a".repeat(57) + " tail", 60) == "a".repeat(57) + "..."
		),
		"a short text stays, an unbroken one is cut hard, a cut on a space adds nothing"
	)
	var e := {"yes": 3, "no": 2, "outcome": "enacted", "override": false}
	check(CL.verdict(e) == "passed 3-2" and CL.score(e) == "3-2", "passed 3-2 (%s)" % CL.verdict(e))
	check(
		(
			CL.verdict({"yes": 2, "no": 1, "outcome": "enacted", "override": true})
			== "OVERRIDE: passed with 2"
		),
		"OVERRIDE: passed with 2"
	)
	check(
		(
			CL.verdict({"yes": 4, "no": 1, "outcome": "deferred", "override": true})
			== "OVERRIDE: deferred with 4 yes"
		),
		"OVERRIDE: deferred with 4 yes"
	)
	check(
		CL.verdict({"yes": 1, "no": 3, "outcome": "rejected", "override": false}) == "rejected 1-3",
		"rejected 1-3"
	)
	check(
		CL.verdict({"yes": 0, "no": 0, "outcome": "repealed", "override": false}) == "repealed",
		"repealed"
	)
	check(
		CL.verdict(5) == "" and CL.verdict({}) == "ruled",
		"a record that is not one reads as nothing"
	)
	var seats := CL.seats({"votes": {"grok": "no", "argon": "yes", "kimi": "Yes!", "zzz": "yes"}})
	check(
		(
			seats["yes"] == ["Ada", "Mei"]
			and seats["no"] == ["Duke"]
			and seats["none"] == ["Viktor", "Rosa"]
		),
		"seats list first names in seat order, anything starting with y is yes (%s)" % str(seats)
	)


# ------------------------------------------------------------------ the majority rule


func _check_majority_rule() -> void:
	var gated := GATED.new()
	gated.name = "Gated"
	gated.live_enabled = false
	var w := _world(gated)
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	var rulings: Array[Dictionary] = []
	brain.council_ruled.connect(func(r: Dictionary) -> void: rulings.append(r))
	brain.proposals = {
		"recycling":
		_prop(0, {"argon": "yes", "deepseek": "yes", "kimi": "yes", "qwen": "yes", "grok": "no"}),
		"curfew": _prop(4, {"grok": "yes", "argon": "yes", "kimi": "no"}),
		"tourism_campaign":
		_prop(2, {"kimi": "yes", "argon": "no", "deepseek": "no", "grok": "no"}),
	}
	await brain._run_council(7)
	check(
		rulings.size() == 1 and (rulings[0]["tally"] as Array).size() == 3,
		"the ruling carries a tally of all three proposals"
	)
	check(
		brain.council_history.size() == 3,
		"and the history holds a record each (%d)" % brain.council_history.size()
	)
	var rec := _record(brain, "recycling")
	check(
		(
			str(rec["outcome"]) == "enacted"
			and int(rec["yes"]) == 4
			and int(rec["no"]) == 1
			and not bool(rec["override"])
		),
		"4 yes carries it, no override"
	)
	check(
		(
			CL.verdict(rec) == "passed 4-1"
			and int(rec["day"]) == 7
			and str(rec["source"]) == "heuristic"
			and str(rec["by_id"]) == "argon"
		),
		"passed 4-1, day, source and proposer (%s)" % CL.verdict(rec)
	)
	check(
		(rec["votes"] as Dictionary).size() == 5 and rec["votes"]["grok"] == "no",
		"the votes of all five are kept as cast"
	)
	check(sim.ordinances.has("recycling"), "the sim enacted it")
	var cur := _record(brain, "curfew")
	check(
		(
			str(cur["outcome"]) == "deferred"
			and CL.verdict(cur) == "deferred 2-1"
			and not bool(cur["override"])
		),
		"2 yes, 1 no stays on the floor: deferred 2-1"
	)
	var tour := _record(brain, "tourism_campaign")
	check(
		(
			str(tour["outcome"]) == "rejected"
			and CL.verdict(tour) == "rejected 1-3"
			and not bool(tour["override"])
		),
		"four votes cast and no majority: rejected 1-3"
	)
	check(
		brain.proposals.keys() == ["curfew"],
		"only the deferred proposal stays (%s)" % str(brain.proposals.keys())
	)
	check(
		(
			str(rulings[0]["tally"][0]["key"]) == "recycling"
			and str(brain.last_council["tally"][1]["outcome"]) == "deferred"
		),
		"last_council keeps the tally for the street"
	)
	_free(w)


# ---------------------------------------------------------------- the Speaker goes against


func _check_speaker_overrides() -> void:
	var net := NET.new()
	net.name = "Net"
	net.live_enabled = true
	var w := _world(net)
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	sim.ordinances["public_transit"] = 3
	brain.proposals = {
		"neighborhood_watch": _prop(1, {"deepseek": "yes", "argon": "yes", "grok": "no"}),
		"free_clinics":
		_prop(2, {"kimi": "yes", "argon": "yes", "qwen": "yes", "deepseek": "no", "grok": "no"}),
		"water_conservation":
		_prop(3, {"qwen": "yes", "kimi": "yes", "argon": "yes", "grok": "no"}),
		"trade_expo": _prop(4, {"grok": "yes", "qwen": "no"}),
	}
	net.by_model[str(D.SUPPORT_AGENTS["council"]["model"])] = {
		"enact": ["neighborhood_watch"],
		"repeal": ["public_transit"],
		"statement": "Grok-4.5 was right: the data supports Neighborhood Watch.",
	}
	await brain._run_council(9)
	var nw := _record(brain, "neighborhood_watch")
	check(
		(
			str(nw["outcome"]) == "enacted"
			and int(nw["yes"]) == 2
			and bool(nw["override"])
			and CL.verdict(nw) == "OVERRIDE: passed with 2"
		),
		"2 yes enacted by the Speaker: OVERRIDE: passed with 2"
	)
	var fc := _record(brain, "free_clinics")
	check(
		(
			str(fc["outcome"]) == "deferred"
			and bool(fc["override"])
			and CL.verdict(fc) == "OVERRIDE: deferred with 3 yes"
		),
		"3 yes held back: OVERRIDE: deferred with 3 yes"
	)
	var wc := _record(brain, "water_conservation")
	check(
		(
			str(wc["outcome"]) == "rejected"
			and bool(wc["override"])
			and CL.verdict(wc) == "OVERRIDE: rejected with 3 yes"
		),
		"3 yes of four votes, not enacted: OVERRIDE: rejected with 3 yes (%s)" % CL.verdict(wc)
	)
	var te := _record(brain, "trade_expo")
	check(
		str(te["outcome"]) == "deferred" and not bool(te["override"]),
		"1 yes, 1 no: an ordinary deferral"
	)
	var rp := _record(brain, "public_transit")
	check(
		(
			str(rp["outcome"]) == "repealed"
			and CL.verdict(rp) == "repealed"
			and not sim.ordinances.has("public_transit")
		),
		"a repeal is a record too"
	)
	check(
		not str(nw["statement"]).contains("Grok") and str(nw["statement"]).contains("Duke Granger"),
		"the statement on a record is de-branded (%s)" % str(nw["statement"]).left(40)
	)
	check(str(nw["source"]) == "live", "and says the Speaker answered live")
	check(
		brain.council_history.size() == 5,
		"five records for four proposals and one repeal (%d)" % brain.council_history.size()
	)
	# Mayor context v2 tells the Gazette's feed about a ruling against the vote; off, it does not.
	FeatureFlags.set_override("mayor_context_v2", false)
	brain.day_feed.clear()
	var held := {"kimi": "yes", "argon": "yes", "qwen": "yes", "deepseek": "no", "grok": "no"}
	brain.proposals = {"trade_expo": _prop(2, held)}
	net.by_model[str(D.SUPPORT_AGENTS["council"]["model"])] = {
		"enact": [], "repeal": [], "statement": "Not yet."
	}
	await brain._run_council(10)
	check(not _feed_has(brain, "went against the vote"), "flag off: the Gazette's feed is not told")
	FeatureFlags.set_override("mayor_context_v2", true)
	brain.proposals = {"tourism_campaign": _prop(2, held)}
	await brain._run_council(11)
	check(
		_feed_has(brain, "The Speaker held back Tourism Campaign despite 3 yes, over the count."),
		"flag on: it is, in prose (%s)" % str(brain.day_feed)
	)
	check(not _feed_has(brain, "OVERRIDE"), "and without the board's capital label")
	FeatureFlags.set_override("mayor_context_v2", false)
	_free(w)


# ------------------------------------------------------------------ offline planners and replay


func _check_offline_splits() -> void:
	var w := _world()
	var brain: CityBrain = w["brain"]
	(w["client"] as GmiClient).replay_cache = {}
	brain.proposals = {
		"clean_air_act": _prop(0, {"argon": "yes"}),
		"curfew": _prop(0, {"argon": "yes"}),
		"recycling": _prop(0, {"argon": "yes"}),
	}
	for mi in range(D.MAYORS.size()):
		await brain._run_mayor(mi, 5)
		check(
			str(brain.mayor_state[mi]["source"]) == "heuristic",
			"offline mayor %d answered from the planner" % mi
		)
	await brain._run_council(5)
	for key: String in ["clean_air_act", "curfew"]:
		var r := _record(brain, key)
		check(
			r["votes"]["grok"] == "no" and int(r["yes"]) == 4 and CL.verdict(r) == "passed 4-1",
			"offline: Duke votes no on %s, the other four yes: %s" % [key, CL.verdict(r)]
		)
	var rec := _record(brain, "recycling")
	check(
		int(rec["no"]) == 0 and CL.verdict(rec) == "passed 5-0",
		"offline: every other proposal is unanimous (%s)" % CL.verdict(rec)
	)
	_free(w)


func _check_replay_votes() -> void:
	var w := _world()
	var brain: CityBrain = w["brain"]
	var client: GmiClient = w["client"]
	check(not client.replay_cache.is_empty(), "fixture: the recorded run is loaded")
	brain.proposals = {
		"clean_air_act": _prop(0, {}),
		"green_energy_subsidy": _prop(0, {}),
		"recycling": _prop(0, {}),
	}
	for mi in range(D.MAYORS.size()):
		await brain._run_mayor(mi, 3)
		check(
			str(brain.mayor_state[mi]["source"]) == "cache",
			"replay mayor %d answered from the recording" % mi
		)
	await brain._run_council(3)
	var ca := _record(brain, "clean_air_act")
	check(
		(
			ca.has("votes")
			and ca["votes"]["grok"] == "no"
			and ca["votes"]["argon"] == "yes"
			and not (ca["votes"] as Dictionary).has("qwen")
		),
		(
			"replay: the recorded votes are on the board (grok no, argon yes, qwen silent): %s"
			% str(ca.get("votes"))
		)
	)
	check(
		str(ca["source"]) == "cache" and int(ca["yes"]) == 3 and int(ca["no"]) == 1,
		"replay: tally %s from the recording" % CL.score(ca)
	)
	var seats := CL.seats(ca)
	check(
		seats["no"] == ["Duke"] and seats["none"] == ["Rosa"],
		"replay: Duke is the one No and Rosa did not vote (%s)" % str(seats)
	)
	var verdicts: Array[String] = []
	for key: String in ["clean_air_act", "green_energy_subsidy", "recycling"]:
		var rr := _record(brain, key)
		verdicts.append(CL.verdict(rr))
		check(
			not bool(rr["override"]) and not CL.verdict(rr).contains("OVERRIDE"),
			"replay: %s is never an override (%s)" % [key, CL.verdict(rr)]
		)
	check(
		str(ca["outcome"]) != "enacted" or not CL.verdict(ca).contains("with"),
		"replay: a recorded ruling does not claim a count it never saw (%s)" % CL.verdict(ca)
	)
	print(
		(
			"  note  replay day 3: clean_air_act %s, green_energy_subsidy %s, recycling %s"
			% [
				CL.verdict(ca),
				CL.verdict(_record(brain, "green_energy_subsidy")),
				CL.verdict(_record(brain, "recycling"))
			]
		)
	)
	_free(w)


# ------------------------------------------------------------------ reasons for votes


func _check_vote_notes() -> void:
	var net := NET.new()
	net.name = "Net"
	net.live_enabled = true
	var w := _world(net)
	var brain: CityBrain = w["brain"]
	FeatureFlags.set_override("mayor_context_v2", true)
	brain.proposals = {"curfew": _prop(0, {"argon": "yes"})}
	var grok: Dictionary = D.MAYORS[4]
	net.by_model[str(grok["model"])] = {
		"thought": "t",
		"public_post": "p",
		"mood": "m",
		"actions": [],
		"propose_ordinance": "",
		"votes": {"curfew": "no"},
		"vote_notes": {"curfew": "A curfew kills nightlife and the boom"},
	}
	await brain._run_mayor(4, 6)
	check(
		str(brain.proposals["curfew"]["notes"]["grok"]) == "A curfew kills nightlife and the boom",
		"a No comes with its reason on the proposal"
	)
	net.by_model[str(D.SUPPORT_AGENTS["council"]["model"])] = {
		"enact": [], "repeal": [], "statement": "Wait for more votes."
	}
	await brain._run_council(6)
	var rec := _record(brain, "curfew")
	check(
		(
			str(rec["notes"]["grok"]).begins_with("A curfew kills")
			and CL.verdict(rec) == "deferred 1-1"
		),
		"and the history keeps it (%s)" % str(rec["notes"])
	)
	var text := _plain(BOARD.history_text(brain))
	check(
		(
			text.contains("Day 6  Youth Curfew: deferred 1-1")
			and text.contains("Duke: A curfew kills nightlife")
		),
		"the board prints the reason under the vote (%s)" % text.replace("\n", " | ").left(160)
	)
	FeatureFlags.set_override("mayor_context_v2", false)
	brain.proposals = {"curfew": _prop(0, {"argon": "yes"})}
	net.by_model[str(grok["model"])]["vote_notes"] = {"curfew": "ignored"}
	await brain._run_mayor(4, 7)
	check(
		(
			not (brain.proposals["curfew"] as Dictionary).has("notes")
			and not (brain.mayor_state[4]["log"][-1] as Dictionary).has("vote_notes")
		),
		"flag off: a vote note in a reply is ignored"
	)
	_free(w)


# ------------------------------------------------------------------ bounds


func _check_bounds() -> void:
	var w := _world()
	var brain: CityBrain = w["brain"]
	for day in range(1, 26):
		CL.record(
			brain,
			{
				"day": day,
				"statement": "s",
				"source": "live",
				"repealed": [],
				"tally":
				[
					{
						"key": "curfew",
						"by": "",
						"by_id": "",
						"votes": {"argon": "yes"},
						"notes": {},
						"yes": 1,
						"no": 0,
						"outcome": "deferred",
						"override": false
					}
				]
			}
		)
	check(
		brain.council_history.size() == CL.KEEP,
		"the history keeps the newest %d rulings (%d)" % [CL.KEEP, brain.council_history.size()]
	)
	check(
		int(brain.council_history[0]["day"]) == 6 and int(brain.council_history[-1]["day"]) == 25,
		(
			"oldest first, newest last (days %d..%d)"
			% [int(brain.council_history[0]["day"]), int(brain.council_history[-1]["day"])]
		)
	)
	brain.setup(w["sim"], w["client"])
	check(
		brain.council_history.is_empty() and brain.notes.is_empty(),
		"New City clears the history and the notes"
	)
	_free(w)


# ------------------------------------------------------------------ the board's text


func _plain(bb: String) -> String:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	get_root().add_child(rt)
	rt.text = bb
	var t := rt.get_parsed_text()
	rt.queue_free()
	return t


func _check_board_text() -> void:
	var w := _world()
	var brain: CityBrain = w["brain"]
	brain.proposals = {
		"curfew": _prop(0, {"argon": "yes", "grok": "no", "kimi": "yes"}),
		"recycling": _prop(1, {"deepseek": "yes"})
	}
	brain.council_history = [
		{
			"day": 2,
			"key": "public_transit",
			"by": "",
			"by_id": "",
			"votes": {},
			"notes": {},
			"yes": 0,
			"no": 0,
			"outcome": "repealed",
			"override": false,
			"statement": "",
			"source": "live"
		},
		{
			"day": 3,
			"key": "recycling",
			"by": "Rosa Quintero",
			"by_id": "qwen",
			"votes": {"qwen": "yes", "argon": "yes"},
			"notes": {},
			"yes": 2,
			"no": 0,
			"outcome": "enacted",
			"override": true,
			"statement": "",
			"source": "live"
		},
		{
			"day": 4,
			"key": "free_clinics",
			"by": "Mei Kimura",
			"by_id": "kimi",
			"votes": {"kimi": "yes", "argon": "yes", "qwen": "yes"},
			"notes": {},
			"yes": 3,
			"no": 0,
			"outcome": "enacted",
			"override": false,
			"statement": "",
			"source": "live"
		},
		{
			"day": 5,
			"key": "curfew",
			"by": "Ada Okafor",
			"by_id": "argon",
			"votes": {"argon": "yes", "kimi": "yes", "grok": "no"},
			"notes": {"grok": "Rules [b]hurt[/b] the boom"},
			"yes": 2,
			"no": 1,
			"outcome": "deferred",
			"override": false,
			"statement": "",
			"source": "live"
		},
	]
	brain.proposals["curfew"]["notes"] = {"grok": "Rules [b]hurt[/b] the boom"}
	var floor := _plain(BOARD.proposals_text(brain))
	check(
		floor.contains("Youth Curfew by Ada Okafor  2-1"),
		"a proposal reads label, proposer and tally (%s)" % floor.replace("\n", " | ").left(120)
	)
	check(
		floor.contains("Ada* Y  Viktor -  Mei Y  Rosa -  Duke N"),
		(
			"its five seats: Y, N or - in seat order, an asterisk after the proposer's name (%s)"
			% floor.replace("\n", " | ")
		)
	)
	check(floor.contains("Viktor* Y"), "each proposal marks its own proposer")
	check(
		not floor.contains("*Y") and floor.contains("* marks the mayor who proposed it"),
		"the mark is never on the vote letter, and the board says what it means"
	)
	check(
		floor.contains("Speaker, day 5: deferred 2-1"),
		"a proposal the Speaker held over shows what it said"
	)
	check(
		not floor.contains("Speaker, day 3"),
		"a record of a ruling that took the proposal off the floor is not shown on it"
	)
	check(
		floor.contains("Duke: Rules [b]hurt[/b] the boom"),
		"the reason shows, escaped (%s)" % floor.replace("\n", " | ")
	)
	check(
		not floor.contains(" yes") and not floor.contains(" no\n"),
		"the old 'N yes N no' words are gone"
	)
	var hist := _plain(BOARD.history_text(brain))
	check(hist.contains("Council record"), "a record section")
	check(
		(
			hist.contains("Day 5  Youth Curfew: deferred 2-1")
			and hist.contains("Day 4  Free Clinics: passed 3-0")
		),
		"newest first, with the verdict (%s)" % hist.replace("\n", " | ").left(150)
	)
	check(
		hist.contains("Day 3  Recycling Program: OVERRIDE: passed with 2"),
		"an override is flagged in capitals"
	)
	check(hist.contains("Day 2  Public Transit Network: repealed"), "a repeal reads as one")
	var raw := BOARD.history_text(brain)
	check(
		(
			raw.contains("[color=%s]OVERRIDE: passed with 2[/color]" % BOARD.WARN)
			and raw.contains("[color=%s]passed 3-0[/color]" % BOARD.DIM)
		),
		"the override row is amber and an ordinary one is dim (get_parsed_text cannot see colour)"
	)
	check(
		hist.find("Day 5") < hist.find("Day 4") and hist.find("Day 4") < hist.find("Day 3"),
		"in order"
	)
	brain.council_history.append(
		{
			"day": 6,
			"key": "curfew",
			"by": "",
			"by_id": "",
			"votes": {"argon": "yes", "kimi": "yes", "qwen": "yes"},
			"notes": {},
			"yes": 3,
			"no": 0,
			"outcome": "deferred",
			"against": true,
			"override": false,
			"statement": "",
			"source": "cache"
		}
	)
	var replayed := _plain(BOARD.history_text(brain))
	check(
		(
			replayed.contains("Day 6  Youth Curfew: deferred (replay, today's votes)")
			and not replayed.contains("Day 6  Youth Curfew: OVERRIDE")
			and not replayed.contains("Day 5  Youth Curfew: deferred 2-1 (")
		),
		"a ruling from the recording says so and is no override: its Speaker never saw the votes"
	)
	brain.council_history.pop_back()
	# The record lists the newest SHOWN rulings and no more.
	var keep := brain.council_history.duplicate(true)
	for k in range(9):
		brain.council_history.append(
			{
				"day": 20 + k,
				"key": "curfew",
				"by": "",
				"by_id": "",
				"votes": {"argon": "yes"},
				"notes": {},
				"yes": 1,
				"no": 0,
				"outcome": "deferred",
				"against": false,
				"override": false,
				"statement": "",
				"source": "live"
			}
		)
	var long_hist := _plain(BOARD.history_text(brain))
	check(
		long_hist.count("Youth Curfew: deferred") == BOARD.SHOWN and long_hist.contains("Day 28"),
		"the record lists the newest %d rulings only (%d)" % [BOARD.SHOWN, long_hist.count("Day ")]
	)
	check(
		not long_hist.contains("Day 22") and long_hist.contains("Day 23"),
		"the seventh newest ruling is not shown"
	)
	brain.council_history = keep
	check(BOARD.notes_text(brain).is_empty(), "no notes section until a live model wrote a note")
	brain.notes = {
		"kimi":
		[
			{
				"from": "argon",
				"day": 6,
				"kind": "note",
				"text": "Share solar [lb]",
				"amount": 0,
				"seen": false
			}
		],
		"deepseek":
		[
			{
				"from": "argon",
				"day": 6,
				"kind": "request",
				"text": "Funds",
				"amount": 600,
				"seen": false
			}
		]
	}
	var notes := _plain(BOARD.notes_text(brain))
	check(
		(
			notes.contains("Ada Okafor to Mei Kimura says: Share solar")
			and notes.contains("Ada Okafor to Viktor Han asks for $600: Funds")
		),
		"notes read speaker, listener and words (%s)" % notes.replace("\n", " | ")
	)
	brain.proposals = {}
	brain.council_history = []
	check(
		(
			_plain(BOARD.proposals_text(brain)).contains("none")
			and BOARD.history_text(brain).is_empty()
		),
		"an empty floor and no record read as none"
	)
	_free(w)
