extends SceneTree
## The limits and guards of mayor context v2 that the documents name (docs/runbooks/
## mayor-context-v2.md, docs/save-schema.md), pinned at their edges: a request is at most $3000,
## the Grid Operator's line is stale after 6 days, the league breaks a tie for the lower seat, a
## mayor with exactly $0 is offered no grant, and a request for $0 is never stored. (The save's own
## limits, notes kept 8 days and none from a mayor to himself: fp_mayor_context_save_test.)
## Headless, offline, fake transport only (support/scripted_net.gd): no key, no network.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const PF := preload("res://tools/tests/support/prompt_fixture.gd")
const MC := preload("res://scripts/ai/mayor_context.gd")
const TOKEN := "FP_MAYOR_CONTEXT_LIMITS_TEST"

var fails: Array[String] = []
var brain: CityBrain
var sim: CitySim


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	var w := PF.build_live(get_root())
	brain = w["brain"]
	sim = w["sim"]
	FeatureFlags.set_override(MC.FLAG, true)
	_check_request_cap()
	_check_zero_request()
	_check_operator_window()
	_check_league_tie()
	_check_broke_mayor()
	FeatureFlags.set_override(MC.FLAG, false)
	K.finish(self, TOKEN, fails)


func _request(amount: int) -> Dictionary:
	return {"request": {"from": "deepseek", "amount": amount, "reason": "Sewage ate my budget"}}


## A request is capped at $3000 as it is read and as it is loaded from a save.
func _check_request_cap() -> void:
	brain.notes = {}
	var entry := {"votes": {}}
	MC.absorb(brain, 0, 7, _request(99999), entry)
	check(
		int(entry.get("request", {}).get("amount", -1)) == 3000,
		"a request for $99999 is cut to $3000 (%s)" % str(entry.get("request"))
	)
	var loaded := MC.restore(
		{
			"deepseek":
			[
				{
					"from": "argon",
					"day": 5,
					"kind": "request",
					"text": "x",
					"amount": 99999,
					"seen": false
				}
			]
		}
	)
	check(
		int(loaded["deepseek"][0]["amount"]) == 3000,
		"a saved request is cut to $3000 as well (%s)" % str(loaded["deepseek"][0]["amount"])
	)
	check(MC.REQUEST_MAX == 3000, "the cap is the documented $3000")
	brain.notes = {}


## A request for nothing is no request.
func _check_zero_request() -> void:
	brain.notes = {}
	var entry := {"votes": {}}
	MC.absorb(brain, 0, 7, _request(0), entry)
	check(
		not entry.has("request") and brain.notes.is_empty(),
		"a request for $0 is neither logged nor delivered (%s)" % str(brain.notes)
	)
	MC.absorb(brain, 0, 7, _request(1), entry)
	check(entry.has("request"), "while one for $1 is")
	brain.notes = {}


## The Grid Operator's order stays in a prompt for OPERATOR_DAYS days and not a day more.
func _check_operator_window() -> void:
	brain.last_operator = {"day": 10, "priority": [0, 1, 2, 3, 4], "note": "Shed east first."}
	check(
		not MC._operator_line(brain, 16).is_empty() and MC._operator_line(brain, 17).is_empty(),
		"the Grid Operator's line is shown 6 days after its order and not on the 7th"
	)
	check(MC.OPERATOR_DAYS == 6, "the window is the documented 6 days")


## Equal scores and districts: the lower seat leads.
func _check_league_tie() -> void:
	var low := {"score": 50, "pop": 10, "mi": 1}
	var high := {"score": 50, "pop": 10, "mi": 3}
	check(MC._ahead(low, high) and not MC._ahead(high, low), "a league tie goes to the lower seat")
	check(
		(
			MC._ahead({"score": 51, "pop": 1, "mi": 4}, high)
			and MC._ahead({"score": 50, "pop": 11, "mi": 4}, high)
		),
		"after the score, the bigger district"
	)


## A mayor with exactly nothing is told to decline, not offered a grant of $0 or a negative sum.
func _check_broke_mayor() -> void:
	var mei := 2
	var keep := int(sim.mayors[mei]["treasury"])
	brain.notes = {
		"kimi":
		[
			{
				"from": "deepseek",
				"day": 6,
				"kind": "request",
				"text": "Funds",
				"amount": 600,
				"seen": false
			}
		]
	}
	sim.mayors[mei]["treasury"] = 0
	var broke := " ".join(PackedStringArray(MC.note_lines(brain, mei, PF.PROMPT_DAY)))
	check(
		broke.contains("no funds to give") and not broke.contains('"type":"grant"'),
		"exactly $0: no grant example (%s)" % broke.right(90)
	)
	sim.mayors[mei]["treasury"] = 1
	var poor := " ".join(PackedStringArray(MC.note_lines(brain, mei, PF.PROMPT_DAY)))
	check(
		poor.contains('"amount":1}') and poor.contains("You hold $1"),
		"$1: the example is capped at the treasury (%s)" % poor.right(90)
	)
	sim.mayors[mei]["treasury"] = keep
	brain.notes = {}
