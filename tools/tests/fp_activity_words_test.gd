extends SceneTree
## What the street's council card says (ActivityWords.council_words, council_fold, council_votes,
## council_news): the headline, a folded card's one line and the vote line for a ruling and its
## tally. A ruling that went against the count says so; a recorded or offline one never claims a
## count it disagrees with; a deferral the council already reported is not news again. Pure text,
## headless.

const K := preload("res://tools/tests/fp_kit.gd")
const W := preload("res://scripts/fp/activity/activity_words.gd")
const R := preload("res://tools/tests/support/council_rulings.gd")
const AF := preload("res://scripts/fp/activity/activity_feed.gd")
const TOKEN := "FP_ACTIVITY_WORDS_TEST"

var fails: Array[String] = []


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	_check_council_words()
	_check_votes_line()
	_check_fold_and_news()
	K.finish(self, TOKEN, fails)


## The headline of the council card, and the old shapes of a ruling.
func _check_council_words() -> void:
	var old_ruling := {"enacted": ["curfew"], "repealed": ["clean_air_act"]}
	K.check(
		fails,
		W.council_words(old_ruling) == "Passed Youth Curfew · Repealed Clean Air Act",
		"a ruling without a tally reads as before"
	)
	K.check(fails, W.council_votes(old_ruling).is_empty(), "and has no vote line")
	var ruling := R.tally_ruling()
	var words := W.council_words(ruling)
	K.check(
		fails,
		words == "Rejected Tourism Campaign despite 3 yes (override) · +2 more",
		"a ruling leads with the one the Speaker went against and counts the rest (%s)" % words
	)
	K.check(fails, words.length() <= W.HEAD_CHARS, "so its headline fits the card's two lines")
	var busy := R.tally_ruling()
	busy["enacted"] = ["curfew", "recycling", "clean_air_act"]
	busy["rejected"] = []
	busy["tally"] = [
		R.seat("curfew", 3, 2, "enacted"),
		R.seat("recycling", 4, 1, "enacted"),
		R.seat("clean_air_act", 5, 0, "enacted"),
		R.seat("tourism_campaign", 1, 1, "deferred"),
	]
	var busy_words := W.council_words(busy)
	K.check(
		fails,
		(
			busy_words == "Passed Youth Curfew 3-2 · Passed Recycling Program 4-1 · +2 more"
			and busy_words.length() <= W.HEAD_CHARS
		),
		"a busy ruling lists what fits and says how many more (%s)" % busy_words
	)
	var many_over := R.tally_ruling()
	many_over["enacted"] = ["recycling", "green_energy_subsidy"]
	many_over["rejected"] = ["clean_air_act"]
	many_over["tally"] = [
		R.seat("recycling", 3, 2, "enacted"),
		R.seat("green_energy_subsidy", 2, 3, "enacted", true),
		R.seat("clean_air_act", 4, 1, "rejected", true),
	]
	var over_words := W.council_words(many_over)
	K.check(
		fails,
		(
			over_words.length() <= W.HEAD_CHARS
			and over_words.contains("(override)")
			and not over_words.ends_with(" ·")
			and over_words.contains("more")
		),
		"three rulings that carry overrides still fit, without a dangling dot (%s)" % over_words
	)
	var replayed := {
		"source": "cache",
		"enacted": [],
		"repealed": [],
		"rejected": ["clean_air_act"],
		"tally": [R.seat("clean_air_act", 4, 1, "rejected", false, true)],
	}
	var replay_words := W.council_words(replayed)
	K.check(
		fails,
		replay_words == "Rejected Clean Air Act",
		"a replayed ruling against the count claims neither count nor override (%s)" % replay_words
	)
	K.check(
		fails,
		not W.council_votes(replayed).begins_with("The Speaker went against"),
		"and its vote line does not say the Speaker went against the vote"
	)
	var votes := W.council_votes(ruling)
	K.check(
		fails,
		votes.begins_with(
			"The Speaker went against the vote. Tourism Campaign: yes Ada, Viktor, Mei · no Rosa"
		),
		"the vote line starts with the one the Speaker went against, in first names (%s)" % votes
	)
	var calm := {"tally": [ruling["tally"][0]], "enacted": ["curfew"]}
	K.check(
		fails,
		W.council_votes(calm) == "Youth Curfew: yes Ada, Viktor, Mei · no Rosa, Duke",
		"a plain ruling lists its seats (%s)" % W.council_votes(calm)
	)
	var waits := {"tally": [ruling["tally"][2]], "enacted": [], "repealed": [], "rejected": []}
	K.check(
		fails,
		W.council_words(waits) == "Held Recycling Program 1-0",
		(
			"a ruling that only held a proposal over says so, not 'no ordinance changed' (%s)"
			% W.council_words(waits)
		)
	)


## The vote line, for a ruling that went against the count and for a replayed one.
func _check_votes_line() -> void:
	var ruling := R.tally_ruling()
	var quiet := {
		"source": "cache",
		"enacted": [],
		"repealed": [],
		"rejected": ["recycling"],
		"tally": [R.seat("recycling", 5, 0, "rejected", false, true)],
	}
	K.check(
		fails,
		(
			W.council_votes(quiet).is_empty()
			and W.council_words(quiet) == "Rejected Recycling Program"
		),
		(
			"a recorded ruling against five yes shows no vote line beside 'Rejected' (%s)"
			% W.council_votes(quiet)
		)
	)
	var mixed := {
		"source": "cache",
		"enacted": ["curfew"],
		"repealed": [],
		"rejected": ["recycling"],
		"tally":
		[R.seat("recycling", 5, 0, "rejected", false, true), R.seat("curfew", 3, 2, "enacted")],
	}
	K.check(
		fails,
		W.council_votes(mixed).begins_with("Youth Curfew: yes Ada, Viktor, Mei"),
		(
			"and with another proposal that agrees, the line is about that one (%s)"
			% W.council_votes(mixed)
		)
	)
	K.check(
		fails,
		W.council_votes(ruling).begins_with("The Speaker went against the vote. Tourism Campaign"),
		"a live override still leads the line"
	)


## A folded card is one line: the override mark stays, repeats are not news.
func _check_fold_and_news() -> void:
	var over := R.tally_ruling()
	over["enacted"] = ["green_energy_subsidy"]
	over["rejected"] = []
	over["tally"] = [
		R.seat("green_energy_subsidy", 2, 3, "enacted", true),
		R.seat("clean_air_act", 3, 2, "enacted"),
		R.seat("curfew", 1, 1, "deferred"),
	]
	over["enacted"] = ["green_energy_subsidy", "clean_air_act"]
	var fold := W.council_fold(over)
	K.check(
		fails,
		(
			fold.begins_with("Passed Green Energy Subsidy (override)")
			and fold.length() <= W.FOLD_CHARS
		),
		"a folded council card keeps '(override)' and fits one line (%s)" % fold
	)
	K.check(fails, fold.ends_with(" +2"), "and counts what it leaves out (%s)" % fold)
	var plain := {"enacted": ["curfew"], "repealed": ["clean_air_act"]}
	K.check(
		fails,
		W.council_fold(plain) == "Passed Youth Curfew +1",
		"a plain ruling folds to its first part and a count (%s)" % W.council_fold(plain)
	)
	var item := {
		"headline": "Passed Youth Curfew 3-2 · Passed Recycling",
		"fold": "Passed Youth Curfew 3-2 +1"
	}
	K.check(
		fails,
		(
			AF._head_text(item, false) == "Passed Youth Curfew 3-2 +1"
			and AF._head_text(item, true) == "Passed Youth Curfew 3-2 · Passed Recycling"
		),
		"the feed shows the fold on a folded card and the full headline on the open one"
	)
	# A deferral the street already heard about is not news; a new one, or one that now goes
	# against the count, is.
	var repeat := R.seat("curfew", 3, 2, "deferred")
	repeat["repeat"] = true
	repeat["news"] = false
	var again := {"enacted": [], "repealed": [], "rejected": [], "tally": [repeat]}
	K.check(
		fails,
		not W.council_news(again) and W.council_words(again) == "No ordinance changed",
		"a repeated deferral is not news (%s)" % W.council_words(again)
	)
	repeat["news"] = true
	K.check(
		fails,
		W.council_news(again) and W.council_words(again) == "Held Youth Curfew 3-2",
		"but the first one is (%s)" % W.council_words(again)
	)
	var over_held := R.seat("curfew", 4, 1, "deferred", true)
	K.check(
		fails,
		(
			W.council_words({"tally": [over_held]}) == "Held Youth Curfew despite 4 yes (override)"
			and W.council_fold({"tally": [over_held]}) == "Held Youth Curfew (override)"
		),
		"a held proposal against the count reads with its override"
	)
	K.check(
		fails,
		W.council_news({"enacted": ["curfew"]}) and W.council_news({}),
		"a ruling without a tally always has news (an old save)"
	)
