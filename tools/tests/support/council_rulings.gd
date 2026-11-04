extends RefCounted
## Council rulings as CityBrain._run_council emits them, for the activity tests: a ruling with a
## tally, and one tally entry from a few numbers.


## Youth Curfew passes 3-2, Tourism Campaign is turned down although 3 voted yes (the Speaker went
## against the count), Recycling waits with one vote.
static func tally_ruling() -> Dictionary:
	return {
		"day": 7,
		"source": "live",
		"statement": "Curfew passes. Grok-4.5 objects.",
		"enacted": ["curfew"],
		"repealed": [],
		"rejected": ["tourism_campaign"],
		"tally":
		[
			{
				"key": "curfew",
				"yes": 3,
				"no": 2,
				"outcome": "enacted",
				"override": false,
				"votes":
				{"argon": "yes", "deepseek": "yes", "kimi": "yes", "qwen": "no", "grok": "no"}
			},
			{
				"key": "tourism_campaign",
				"yes": 3,
				"no": 1,
				"outcome": "rejected",
				"override": true,
				"votes": {"argon": "yes", "deepseek": "yes", "kimi": "yes", "qwen": "no"}
			},
			{
				"key": "recycling",
				"yes": 1,
				"no": 0,
				"outcome": "deferred",
				"override": false,
				"votes": {"argon": "yes"}
			},
		],
	}


## One entry of a ruling's tally: key, yes and no votes (the first yes mayors vote yes, the rest
## no), the outcome, whether the Speaker went against the count (override) and against (a replay).
static func seat(
	key: String, yes: int, no: int, outcome: String, override: bool = false, against: bool = false
) -> Dictionary:
	var votes := {}
	var ids := ["argon", "deepseek", "kimi", "qwen", "grok"]
	for k in range(yes + no):
		votes[ids[k]] = "yes" if k < yes else "no"
	return {
		"key": key,
		"yes": yes,
		"no": no,
		"outcome": outcome,
		"override": override,
		"against": against or override,
		"votes": votes
	}
